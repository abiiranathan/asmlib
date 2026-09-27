/*==============================================================================
 * trig.c - trigonometric routines: sin, cos, tan, sincos
 *------------------------------------------------------------------------------
 * Freestanding, no libc/libm, no errno, no floating-point environment, no
 * mutable global state. Every helper below is static.
 *
 * Structure (the classic Sun fdlibm decomposition, rewritten on top of the
 * local bit-punning helpers so it compiles unchanged for wasm32 and x86-64):
 *
 *   rem_pio2(x, y)       argument reduction. Returns n with
 *                        x - n*pi/2 = y[0] + y[1], |y[0]+y[1]| <= pi/4.
 *                        |x| below ~5pi/4 uses an exact 33-bit pi/2 split;
 *                        the medium range uses a 33-bit-per-word pi/2 and a
 *                        round-to-nearest n; huge |x| falls back to a Payne-
 *                        Hanek reducer driven by a 2/pi bit table, so the
 *                        reduction stays exact for every finite double.
 *
 *   kernel_sin/cos/tan   minimax polynomials on [-pi/4, pi/4]. The tail y[1]
 *                        of the reduced argument is folded in analytically
 *                        (sin(x+y), cos(x+y), tan(x+y) with derivative
 *                        corrections) instead of losing it to rounding.
 *
 *   sin/cos/tan          pick the kernel and the sign from n mod 4; sincos
 *                        reduces once and evaluates both kernels.
 *
 * Results are faithful (< 1 ulp) and the special values are exact:
 *   sin(+-0) = +-0, cos(+-0) = 1, tan(+-0) = +-0,
 *   sin/cos/tan(+-Inf) = NaN, NaN propagates.
 *============================================================================*/

#include "math_private.h"

/* --- word helpers -------------------------------------------------------- */

/*==============================================================================
 * static int32_t hi_word(double x)
 *------------------------------------------------------------------------------
 * High 32 bits of the binary64 encoding: sign, biased exponent and the top
 * 20 mantissa bits.
 *
 * Parameters:
 *   x (double) - any double; its bit pattern is reinterpreted, never computed
 * Returns:
 *   The top 32 bits of the IEEE-754 encoding as a signed int32_t
 * Special cases:
 *   None; bitwise for zeros, subnormals, infinities and NaN alike
 * Accuracy / algorithm:
 *   Exact extraction through f64_bits(); no arithmetic
 *============================================================================*/
static int32_t hi_word(double x)
{
    return (int32_t)(f64_bits(x) >> 32);
}

/*==============================================================================
 * static uint32_t lo_word(double x)
 *------------------------------------------------------------------------------
 * Low 32 mantissa bits of the binary64 encoding.
 *
 * Parameters:
 *   x (double) - any double; its bit pattern is reinterpreted, never computed
 * Returns:
 *   The low 32 bits of the IEEE-754 encoding as an unsigned uint32_t
 * Special cases:
 *   None; bitwise for zeros, subnormals, infinities and NaN alike
 * Accuracy / algorithm:
 *   Exact extraction through f64_bits(); no arithmetic
 *============================================================================*/
static uint32_t lo_word(double x)
{
    return (uint32_t)f64_bits(x);
}

/*==============================================================================
 * Payne-Hanek support: the bits of 2/pi, 24 per 32-bit word.
 *
 * ipio2[i] * 2^(-24*(i+1)) is the (24*i)-th to (24*i+23)-th bit of 2/pi after
 * the binary point. 66 words (396 hex digits) are more than enough for a
 * binary64 input, whose scaled exponent e0 never exceeds 1000 (needs about
 * (e0-3)/24 + 4 = 45 words).
 *============================================================================*/
static const int32_t ipio2[] = {
    0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
    0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
    0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
    0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
    0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
    0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
    0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
    0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
    0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
    0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
    0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,
};

/* pi/2 cut into 24-bit chunks: PIo2[k] = fraction of pi/2 in bits
 * [24k, 24k+23]. */
static const double PIo2[] = {
    1.57079625129699707031e+00, /* 0x3FF921FB, 0x40000000 */
    7.54978941586159635335e-08, /* 0x3E74442D, 0x00000000 */
    5.39030252995776476554e-15, /* 0x3CF84698, 0x80000000 */
    3.28200341580791294123e-22, /* 0x3B78CC51, 0x60000000 */
    1.27065575308067607349e-29, /* 0x39F01B83, 0x80000000 */
    1.22933308981111328932e-36, /* 0x387A2520, 0x40000000 */
    2.73370053816464559624e-44, /* 0x36E38222, 0x80000000 */
    2.16741683877804819444e-51, /* 0x3579F31D, 0x00000000 */
};

static const int32_t init_jk[] = { 3, 4, 4, 6 };  /* initial jk by precision */

/*==============================================================================
 * static int kernel_rem_pio2(double *x, double *y, int e0, int nx, int prec)
 *------------------------------------------------------------------------------
 * Payne-Hanek reduction. x[] holds the positive argument split into nx
 * 24-bit chunks with x[0] carrying scale 2^e0; the returned integer is the
 * low three bits of n and y = x - n*pi/2 satisfies |y| <= pi/2. Only prec=1
 * (double, 53 bits) is ever used here.
 *
 * Parameters:
 *   x    (double *) - nx 24-bit chunks of |x|, x[0] weighted 2^e0
 *   y    (double *) - output double-double: y[0] + y[1] = x - n*pi/2
 *   e0   (int)      - leading-chunk exponent, ilogb(|x|) - 23
 *   nx   (int)      - number of valid chunks in x[], 1..3
 *   prec (int)      - working-precision selector; only 1 (double) is used
 * Returns:
 *   n & 7, the reduction multiple modulo 8 (callers use n mod 4 or n mod 2)
 * Special cases:
 *   If the leading product cancels (z == 0) further 2/pi terms are pulled in
 *   and the base-2^24 distill restarts via `goto recompute`, keeping the
 *   reduction exact even for near-multiples of pi/2
 * Accuracy / algorithm:
 *   Payne-Hanek using a 66-word 2/pi table (24 bits per word) and pi/2 cut
 *   into 24-bit chunks; every partial product stays below 2^24 so the double
 *   arithmetic is exact, and the result is compressed to a double-double
 *============================================================================*/
static int kernel_rem_pio2(double *x, double *y, int e0, int nx, int prec)
{
    int32_t jz, jx, jv, jp, jk, carry, n, iq[20], i, j, k, m, q0, ih;
    double z, fw, f[20], fq[20] = { 0.0 }, q[20];

    jk = init_jk[prec];
    jp = jk;

    /* jv selects the first ipio2[] word that is still integer after the
     * product with x[0]*2^e0; q0 is the matching binary exponent. */
    jx = nx - 1;
    jv = (e0 - 3) / 24;
    if (jv < 0)
        jv = 0;
    q0 = e0 - 24 * (jv + 1);

    /* ---- fetch the window of 2/pi words that overlaps x ---- */
    j = jv - jx;                                    /* alignment of x[] on the table */
    m = jx + jk;
    for (i = 0; i <= m; i++, j++)
        f[i] = (j < 0) ? 0.0 : (double)ipio2[j];    /* zero-fill below ipio2[0] */

    /* ---- q[0..jk] = 24-bit chunks of x * (2/pi) ---- */
    for (i = 0; i <= jk; i++) {
        for (j = 0, fw = 0.0; j <= jx; j++)
            fw += x[j] * f[jx + i - j];
        q[i] = fw;
    }

    jz = jk;                                        /* number of active q[] terms */
recompute:
    /* ---- distill q[] into base-2^24 digits iq[], least significant first ---- */
    for (i = 0, j = jz, z = q[jz]; j > 0; i++, j--) {
        fw = (double)((int32_t)(5.96046447753906250000e-08 * z));   /* 2^-24 */
        iq[i] = (int32_t)(z - 1.67772160000000000000e+07 * fw);     /* 2^24 */
        z = q[j - 1] + fw;                          /* carry into the next digit */
    }

    /* ---- extract n = floor(z); only n mod 8 is needed ---- */
    z = ASM_MATH(scalbn)(z, q0);                    /* restore the binary point */
    z -= 8.0 * ASM_MATH(floor)(z * 0.125);          /* trim integers >= 8 */
    n = (int32_t)z;
    z -= (double)n;                                 /* z is now just the fraction */
    ih = 0;
    if (q0 > 0) {                                   /* need iq[jz-1] for n */
        i = (iq[jz - 1] >> (24 - q0));              /* top q0 bits complete n */
        n += i;
        iq[jz - 1] -= i << (24 - q0);               /* drop those bits */
        ih = iq[jz - 1] >> (23 - q0);               /* rounding bit for 1-q */
    } else if (q0 == 0) {
        ih = iq[jz - 1] >> 23;                      /* rounding bit from top digit */
    } else if (z >= 0.5) {
        ih = 2;                                     /* no digit left: round by z */
    }

    /* ---- fraction rounded up: reflect q -> 1-q and propagate the borrow ---- */
    if (ih > 0) {                                   /* q > 0.5: use 1-q */
        n += 1;
        carry = 0;
        for (i = 0; i < jz; i++) {
            j = iq[i];
            if (carry == 0) {
                if (j != 0) {
                    carry = 1;
                    iq[i] = 0x1000000 - j;          /* 2^24 - j flips the digit */
                }
            } else {
                iq[i] = 0xffffff - j;               /* one's complement digit */
            }
        }
        if (q0 > 0) {                               /* rare: 1 in 12 */
            switch (q0) {
            case 1: iq[jz - 1] &= 0x7fffff; break;  /* keep the low 23 bits */
            case 2: iq[jz - 1] &= 0x3fffff; break;  /* keep the low 22 bits */
            }
        }
        if (ih == 2) {
            z = 1.0 - z;
            if (carry != 0)
                z -= ASM_MATH(scalbn)(1.0, q0);     /* subtract the borrow weight */
        }
    }

    /* ---- cancellation recovery: pull in more 2/pi terms and restart ----
     * The integer part may have cancelled away entirely; if so, pull in
     * more 2/pi terms and start over with higher precision. */
    if (z == 0.0) {
        j = 0;
        for (i = jz - 1; i >= jk; i--)
            j |= iq[i];
        if (j == 0) {
            for (k = 1; iq[jk - k] == 0; k++)
                ;                                   /* k terms needed */
            for (i = jz + 1; i <= jz + k; i++) {
                f[jx + i] = (double)ipio2[jv + i];
                for (j = 0, fw = 0.0; j <= jx; j++)
                    fw += x[j] * f[jx + i - j];
                q[i] = fw;
            }
            jz += k;
            goto recompute;
        }
    }

    /* ---- chop zero terms and split z into a final 24-bit chunk ---- */
    if (z == 0.0) {
        jz -= 1;
        q0 -= 24;
        while (iq[jz] == 0) {
            jz--;
            q0 -= 24;
        }
    } else {
        z = ASM_MATH(scalbn)(z, -q0);
        if (z >= 1.67772160000000000000e+07) {
            fw = (double)((int32_t)(5.96046447753906250000e-08 * z));
            iq[jz] = (int32_t)(z - 1.67772160000000000000e+07 * fw);
            jz += 1;
            q0 += 24;
            iq[jz] = (int32_t)fw;
        } else {
            iq[jz] = (int32_t)z;
        }
    }

    /* ---- float the integer chunks and multiply by the pi/2 chunks ---- */
    fw = ASM_MATH(scalbn)(1.0, q0);
    for (i = jz; i >= 0; i--) {
        q[i] = fw * (double)iq[i];                  /* iq[i] scaled by 2^q0 */
        fw *= 5.96046447753906250000e-08;           /* next digit: * 2^-24 */
    }
    for (i = jz; i >= 0; i--) {
        for (fw = 0.0, k = 0; k <= jp && k <= jz - i; k++)
            fw += PIo2[k] * q[i + k];               /* PIo2 * (2/pi) chunks */
        fq[jz - i] = fw;
    }

    /* ---- compress fq[] into a double-double y[0] + y[1] ---- */
    fw = 0.0;
    for (i = jz; i >= 0; i--)
        fw += fq[i];
    y[0] = (ih == 0) ? fw : -fw;
    fw = fq[0] - fw;
    for (i = 1; i <= jz; i++)
        fw += fq[i];
    y[1] = (ih == 0) ? fw : -fw;

    return n & 7;
}

/*==============================================================================
 * static int rem_pio2(double x, double *y)
 *------------------------------------------------------------------------------
 * Split x into n and the remainder y[0]+y[1] = x - n*pi/2 with the sum in
 * [-pi/4, pi/4]. n is only meaningful modulo 4 (the large path already
 * returns it masked to three bits, which is all the callers use).
 *
 * Parameters:
 *   x (double)   - finite argument of any magnitude
 *   y (double *) - output double-double: y[0] + y[1] = x - n*pi/2
 * Returns:
 *   The reduction multiple n: exact in {-4..4} in the small tier, exact from
 *   the rounding trick in the medium tier, and n & 7 in the Payne-Hanek tier
 * Special cases:
 *   Inf and NaN return 0 with y[0] = y[1] = x - x (a quiet NaN)
 * Accuracy / algorithm:
 *   Three tiers, cheapest first:
 *     small  - |x| <= 9pi/4 uses the exact 33-bit pio2_1/pio2_1t split and a
 *              fixed n in {-4..4}, with near-multiples of pi/2 sent to medium;
 *     medium - |x| < 2^20*(pi/2) uses the 2^52 round-to-nearest trick for
 *              n = rint(x*2/pi) and up to three pi/2 words (~85/118/151 bits);
 *     large  - everything else is chunked to 24 bits and reduced by
 *              kernel_rem_pio2 (Payne-Hanek)
 *============================================================================*/
static int rem_pio2(double x, double *y)
{
    static const double
        invpio2 = 6.36619772367581382433e-01, /* 2/pi        0x3FE45F30 */
        pio2_1  = 1.57079632673412561417e+00, /* pi/2 word 1 0x3FF921FB */
        pio2_1t = 6.07710050650619224932e-11, /* pi/2 tail 1 0x3DD0B461 */
        pio2_2  = 6.07710050630396597660e-11, /* pi/2 word 2 0x3DD0B461 */
        pio2_2t = 2.02226624879595063154e-21, /* pi/2 tail 2 0x3BA3198A */
        pio2_3  = 2.02226624871116645580e-21, /* pi/2 word 3 0x3BA3198A */
        pio2_3t = 8.47842766036889956997e-32; /* pi/2 tail 3 0x397B839A */

    double z, w, t, r, fn, tx[3], ty[2];
    int e0, i, j, nx, n, ix, hx;
    uint32_t low;

    hx = hi_word(x);
    ix = hx & 0x7fffffff;
    /* ---- small tier: |x| <= 9pi/4, exact 33-bit pi/2 split ----
     * Each branch forms z = x -/+ n*pio2_1 and recovers the exact rounding
     * tail with the compensated difference y[1] = (z - y[0]) -/+ n*pio2_1t. */
    if (ix <= 0x400f6a7a) {                         /* |x| ~<= 5pi/4 */
        if ((ix & 0xfffff) == 0x921fb)              /* x ~ n*pi/2: cancel */
            goto medium;
        if (ix <= 0x4002d97c) {                     /* |x| ~<= 3pi/4 */
            if (hx > 0) {
                z = x - pio2_1;
                y[0] = z - pio2_1t;
                y[1] = (z - y[0]) - pio2_1t;
                return 1;
            } else {
                z = x + pio2_1;
                y[0] = z + pio2_1t;
                y[1] = (z - y[0]) + pio2_1t;
                return -1;
            }
        } else {
            if (hx > 0) {
                z = x - 2 * pio2_1;
                y[0] = z - 2 * pio2_1t;
                y[1] = (z - y[0]) - 2 * pio2_1t;
                return 2;
            } else {
                z = x + 2 * pio2_1;
                y[0] = z + 2 * pio2_1t;
                y[1] = (z - y[0]) + 2 * pio2_1t;
                return -2;
            }
        }
    }
    if (ix <= 0x401c463b) {                         /* |x| ~<= 9pi/4 */
        if (ix <= 0x4015fdbc) {                     /* |x| ~<= 7pi/4 */
            if (ix == 0x4012d97c)                   /* x ~ 3pi/2 */
                goto medium;
            if (hx > 0) {
                z = x - 3 * pio2_1;
                y[0] = z - 3 * pio2_1t;
                y[1] = (z - y[0]) - 3 * pio2_1t;
                return 3;
            } else {
                z = x + 3 * pio2_1;
                y[0] = z + 3 * pio2_1t;
                y[1] = (z - y[0]) + 3 * pio2_1t;
                return -3;
            }
        } else {
            if (ix == 0x401921fb)                   /* x ~ 2pi */
                goto medium;
            if (hx > 0) {
                z = x - 4 * pio2_1;
                y[0] = z - 4 * pio2_1t;
                y[1] = (z - y[0]) - 4 * pio2_1t;
                return 4;
            } else {
                z = x + 4 * pio2_1;
                y[0] = z + 4 * pio2_1t;
                y[1] = (z - y[0]) + 4 * pio2_1t;
                return -4;
            }
        }
    }
    /* ---- medium tier: |x| < 2^20*(pi/2), n = rint(x*2/pi) ---- */
    if (ix < 0x413921fb) {                          /* |x| < 2^20*(pi/2) */
medium:
        /* fn = rint(x*2/pi): the 2^52 trick needs round-to-nearest, the only
         * mode this library assumes. */
        fn = x * invpio2 + 0x1.8p52;
        fn = fn - 0x1.8p52;
        n = (int)fn;
        r = x - fn * pio2_1;
        w = fn * pio2_1t;                           /* ~85 bits of pi/2 */
        {
            /* Detect cancellation: i counts the leading bits lost, so further
             * pi/2 words are pulled in only when they are actually needed. */
            uint32_t high;
            j = ix >> 20;
            y[0] = r - w;
            high = (uint32_t)(f64_bits(y[0]) >> 32);
            i = j - (int)((high >> 20) & 0x7ff);
            if (i > 16) {                           /* need ~118 bits */
                t = r;
                w = fn * pio2_2;
                r = t - w;
                w = fn * pio2_2t - ((t - r) - w);
                y[0] = r - w;
                high = (uint32_t)(f64_bits(y[0]) >> 32);
                i = j - (int)((high >> 20) & 0x7ff);
                if (i > 49) {                       /* need ~151 bits */
                    t = r;
                    w = fn * pio2_3;
                    r = t - w;
                    w = fn * pio2_3t - ((t - r) - w);
                    y[0] = r - w;
                }
            }
        }
        y[1] = (r - y[0]) - w;
        return n;
    }

    /* ---- large tier: |x| >= 2^20*(pi/2), 24-bit chunks + Payne-Hanek ---- */
    if (ix >= 0x7ff00000) {                         /* Inf or NaN */
        y[0] = y[1] = x - x;                        /* quiet NaN */
        return 0;
    }
    /* Split |x| * 2^-e0 into three base-2^24 digits (2^24 = 1.6777216e7). */
    low = lo_word(x);
    e0 = (ix >> 20) - 1046;                         /* ilogb(|x|) - 23 */
    {
        uint64_t u = ((uint64_t)(uint32_t)(ix - (e0 << 20)) << 32) | low;
        z = f64_from_bits(u);                       /* z = |x| * 2^-e0 */
    }
    tx[0] = (double)((int32_t)z);                   /* top 24-bit digit */
    z = (z - tx[0]) * 1.67772160000000000000e+07;   /* 2^24: next digit */
    tx[1] = (double)((int32_t)z);                   /* middle 24-bit digit */
    z = (z - tx[1]) * 1.67772160000000000000e+07;   /* 2^24: next digit */
    tx[2] = z;                                      /* low 24-bit digit */
    nx = 3;
    while (tx[nx - 1] == 0.0)
        nx--;                                       /* skip zero terms */
    n = kernel_rem_pio2(tx, ty, e0, nx, 1);
    /* ---- restore the sign of x (the reducer works on |x|) ---- */
    if (hx < 0) {
        y[0] = -ty[0];
        y[1] = -ty[1];
        return -n;
    }
    y[0] = ty[0];
    y[1] = ty[1];
    return n;
}

/*==============================================================================
 * Kernels on [-pi/4, pi/4]. y is the tail of the reduced argument; iy tells
 * whether y is meaningful (0 -> ignore it, and preserves the oddness needed
 * for sin(-0) = -0 in the caller).
 *============================================================================*/

/*==============================================================================
 * static double kernel_sin(double x, double y, int iy)
 *------------------------------------------------------------------------------
 * sin(x + y) on the reduced interval |x| <= pi/4, y the low tail of the
 * reduced argument.
 *
 * Parameters:
 *   x  (double) - leading reduced argument, |x| <= pi/4
 *   y  (double) - tail of the reduced argument, |y| << |x|
 *   iy (int)    - 0 ignores y (preserving the oddness needed for sin(-0) = -0),
 *                 non-zero folds y into the result analytically
 * Returns:
 *   sin(x + y); with iy == 0 this is exactly x + x^3*R(x^2), an odd function
 * Special cases:
 *   x = +-0 with iy == 0 yields +-0; y is assumed finite and consistent with x
 * Accuracy / algorithm:
 *   degree-13 odd minimax polynomial (S1..S6); the tail is folded through the
 *   derivative form x + (S1*x^3 + (x^3*(r - y/2) + y)), r even, keeping the
 *   error below 1 ulp instead of adding y separately
 *============================================================================*/
static double kernel_sin(double x, double y, int iy)
{
    static const double
        half = 5.00000000000000000000e-01,
        S1 = -1.66666666666666324348e-01,
        S2 =  8.33333333332248946124e-03,
        S3 = -1.98412698298579493134e-04,
        S4 =  2.75573137070700676789e-06,
        S5 = -2.50507602534068634195e-08,
        S6 =  1.58969099521155010221e-10;

    /* ---- minimax odd polynomial evaluation and tail folding ---- */
    double z = x * x;
    double w = z * z;
    double r = S2 + z * (S3 + z * S4) + z * w * (S5 + z * S6);
    double v = z * x;
    if (iy == 0)
        return x + v * (S1 + z * r);                 /* y is not meaningful */
    return x - ((z * (half * y - v * r) - y) - v * S1); /* fold in the tail */
}

/*==============================================================================
 * static double kernel_cos(double x, double y)
 *------------------------------------------------------------------------------
 * cos(x + y) on the reduced interval |x| <= pi/4.
 *
 * Parameters:
 *   x (double) - leading reduced argument, |x| <= pi/4
 *   y (double) - tail of the reduced argument, |y| << |x|
 * Returns:
 *   cos(x + y) = (1 - x^2/2) + (correction + (r - x*y)), an even function
 * Special cases:
 *   cos(+-0) = 1 exactly: the polynomial terms vanish and the correction is 0
 * Accuracy / algorithm:
 *   degree-14 even minimax polynomial split as
 *   r = z*(C1+z*(C2+z*C3)) + w*w*(C4+z*(C5+z*C6)), z = x^2, w = z^2; the
 *   1 - z/2 term is compensated against the x*y tail for < 1 ulp
 *============================================================================*/
static double kernel_cos(double x, double y)
{
    static const double
        C1 =  4.16666666666666019037e-02,
        C2 = -1.38888888888741095749e-03,
        C3 =  2.48015872894767294178e-05,
        C4 = -2.75573143513906633035e-07,
        C5 =  2.08757232129817482790e-09,
        C6 = -1.13596475577881948265e-11;

    /* ---- even minimax polynomial and the 1 - z/2 compensation ---- */
    double z = x * x;
    double w = z * z;
    double r = z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6));
    double hz = 0.5 * z;                            /* x^2/2 */
    w = 1.0 - hz;
    return w + (((1.0 - w) - hz) + (z * r - x * y)); /* exact 1-hz correction */
}

/*==============================================================================
 * static double kernel_tan(double x, double y, int iy)
 *------------------------------------------------------------------------------
 * tan(x + y), or -1/tan(x + y) when iy == -1, on the reduced argument.
 *
 * Parameters:
 *   x  (double) - leading reduced argument, |x| <= pi/4
 *   y  (double) - tail of the reduced argument, |y| << |x|
 *   iy (int)    - 1 to return tan(x + y), -1 to return -1/tan(x + y)
 * Returns:
 *   tan(x + y) for iy == 1, -1/tan(x + y) for iy == -1; the caller restores
 *   the quadrant and sign from the reduction multiple
 * Special cases:
 *   +-0 with iy == 1 yields +-0 (the caller short-circuits |x| < 2^-27); the
 *   reciprocal branch assumes w = x + r is not near zero on [-pi/4, pi/4]
 * Accuracy / algorithm:
 *   degree-13 odd minimax polynomial (T[0..12]); for |x| >= 0.6744 x is first
 *   folded through x = (pi/4 - x) - y so the series only sees a small residual,
 *   and the sign is restored from the input's sign bit; the reciprocal uses a
 *   two-word quotient to stay below 1 ulp
 *============================================================================*/
static double kernel_tan(double x, double y, int iy)
{
    static const double T[] = {
         3.33333333333334091986e-01,
         1.33333333333201242699e-01,
         5.39682539762260521377e-02,
         2.18694882948595424599e-02,
         8.86323982359930005737e-03,
         3.59207910759131235356e-03,
         1.45620945432529025516e-03,
         5.88041240820264096874e-04,
         2.46463134818469906812e-04,
         7.81794442939557092300e-05,
         7.14072491382608190305e-05,
        -1.85586374855275456654e-05,
         2.59073051863633712884e-05,
         1.00000000000000000000e+00,             /* one   */
         7.85398163397448278999e-01,             /* pio4  */
         3.06161699786838301793e-17,             /* pio4lo*/
    };
    double z, r, v, w, s;
    int32_t hx = hi_word(x);
    int32_t ix = hx & 0x7fffffff;

    /* ---- fold |x| >= 0.6744 through pi/4 so the series sees a small x ---- */
    if (ix >= 0x3FE59428) {                         /* |x| >= 0.6744 */
        if (hx < 0) {
            x = -x;
            y = -y;                                 /* work with |x| */
        }
        z = 0.785398163397448278999 - x;            /* pio4 - x */
        w = 3.06161699786838301793e-17 - y;         /* pio4lo - y */
        x = z + w;
        y = 0.0;                                    /* tail absorbed above */
    }
    /* ---- odd minimax polynomial and analytic tail correction ---- */
    z = x * x;
    w = z * z;
    r = T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))));
    v = z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))));
    s = z * x;
    r = y + z * (s * (r + v) + y);                  /* fold in the y tail */
    r += T[0] * s;                                  /* leading T[0]*x^3 term */
    w = x + r;
    /* ---- pi/4 fold: tan -> cot, recover via the reciprocal form ---- */
    if (ix >= 0x3FE59428) {
        v = (double)iy;
        return (double)(1 - ((hx >> 30) & 2)) *
               (v - 2.0 * (x - (w * w / (w + v) - r)));
    }
    if (iy == 1)
        return w;
    /* ---- accurate -1/(x+r) via a two-word quotient ---- */
    {
        double a, t;
        z = w;
        z = f64_from_bits(f64_bits(z) & 0xffffffff00000000ULL); /* low 32 = 0 */
        v = r - (z - x);                            /* z + v = r + x */
        t = a = -1.0 / w;
        t = f64_from_bits(f64_bits(t) & 0xffffffff00000000ULL); /* low 32 = 0 */
        s = 1.0 + t * z;
        return t + a * (s + t * v);
    }
}

/*==============================================================================
 * double ASM_MATH(sin)(double x)
 * double ASM_MATH(cos)(double x)
 * void   ASM_MATH(sincos)(double x, double *sinp, double *cosp)
 *------------------------------------------------------------------------------
 * All three share sin_cos_impl: the argument is reduced once, then the two
 * kernels are selected and signed by n mod 4. sin/cos expose one half each.
 *============================================================================*/

/*==============================================================================
 * static void sin_cos_impl(double x, double *sp, double *cp)
 *------------------------------------------------------------------------------
 * Evaluate both sin(x) and cos(x) from a single argument reduction.
 *
 * Parameters:
 *   x  (double)   - any finite or non-finite argument, in radians
 *   sp (double *) - output: sin(x)
 *   cp (double *) - output: cos(x)
 * Returns:
 *   Nothing; *sp and *cp receive the results
 * Special cases:
 *   |x| <= pi/4: |x| < 2^-26 and |x| < 2^-27*sqrt2 short-circuit so that
 *   sin(+-0) = +-0 and cos(+-0) = 1 are exact; Inf/NaN write x - x (a quiet
 *   NaN) to both outputs; otherwise n mod 4 selects the kernel and signs
 * Accuracy / algorithm:
 *   One rem_pio2 reduction (small/medium/Payne-Hanek), then the
 *   kernel_sin/kernel_cos pair on the reduced argument; faithful (< 1 ulp)
 *============================================================================*/
static void sin_cos_impl(double x, double *sp, double *cp)
{
    double y[2], z = 0.0;
    int32_t hx, ix, n;

    hx = hi_word(x);
    ix = hx & 0x7fffffff;

    /* ---- special-case dispatch: tiny |x| and the direct kernel band ---- */
    if (ix <= 0x3fe921fb) {                         /* |x| <= pi/4 */
        if (ix < 0x3e500000)                        /* |x| < 2^-26 */
            *sp = x;                                /* also sin(+-0) = +-0 */
        else
            *sp = kernel_sin(x, z, 0);              /* y is zero in this band */
        if (ix < 0x3e46a09e)                        /* |x| < 2^-27*sqrt2 */
            *cp = 1.0;                              /* also cos(+-0) = 1 */
        else
            *cp = kernel_cos(x, z);
        return;
    }

    /* ---- non-finite arguments: write a quiet NaN to both outputs ---- */
    if (ix >= 0x7ff00000) {                         /* Inf or NaN */
        double nan = x - x;
        *sp = nan;
        *cp = nan;
        return;
    }

    /* ---- reduce once, then pick kernels and signs from quadrant n mod 4 ---- */
    n = rem_pio2(x, y);
    switch (n & 3) {
    case 0:                                         /* sin(y), cos(y) */
        *sp = kernel_sin(y[0], y[1], 1);
        *cp = kernel_cos(y[0], y[1]);
        break;
    case 1:                                         /* cos(y), -sin(y) */
        *sp = kernel_cos(y[0], y[1]);
        *cp = -kernel_sin(y[0], y[1], 1);
        break;
    case 2:                                         /* -sin(y), -cos(y) */
        *sp = -kernel_sin(y[0], y[1], 1);
        *cp = -kernel_cos(y[0], y[1]);
        break;
    default:                                        /* -cos(y), sin(y) */
        *sp = -kernel_cos(y[0], y[1]);
        *cp = kernel_sin(y[0], y[1], 1);
        break;
    }
}

/*==============================================================================
 * double ASM_MATH(sin)(double x)
 *------------------------------------------------------------------------------
 * Sine of x, in radians.
 *
 * Parameters:
 *   x (double) - angle in radians, any magnitude (reduced internally)
 * Returns:
 *   sin(x); sin(+-0) = +-0 and sin(+-Inf) = NaN
 * Special cases:
 *   NaN propagates; |x| <= pi/4 is evaluated by the kernel directly
 * Accuracy / algorithm:
 *   sin_cos_impl -> rem_pio2 + kernel_sin; faithful (< 1 ulp)
 *============================================================================*/
double ASM_MATH(sin)(double x)
{
    double s, c;
    sin_cos_impl(x, &s, &c);                        /* cosine result discarded */
    return s;
}

/*==============================================================================
 * double ASM_MATH(cos)(double x)
 *------------------------------------------------------------------------------
 * Cosine of x, in radians.
 *
 * Parameters:
 *   x (double) - angle in radians, any magnitude (reduced internally)
 * Returns:
 *   cos(x); cos(+-0) = 1 and cos(+-Inf) = NaN
 * Special cases:
 *   NaN propagates; |x| <= pi/4 is evaluated by the kernel directly
 * Accuracy / algorithm:
 *   sin_cos_impl -> rem_pio2 + kernel_cos; faithful (< 1 ulp)
 *============================================================================*/
double ASM_MATH(cos)(double x)
{
    double s, c;
    sin_cos_impl(x, &s, &c);                        /* sine result discarded */
    return c;
}

/*==============================================================================
 * void ASM_MATH(sincos)(double x, double *sinp, double *cosp)
 *------------------------------------------------------------------------------
 * Sine and cosine of x in one pass, sharing a single argument reduction.
 *
 * Parameters:
 *   x    (double)   - angle in radians, any magnitude
 *   sinp (double *) - output: sin(x)
 *   cosp (double *) - output: cos(x)
 * Returns:
 *   Nothing; writes *sinp and *cosp
 * Special cases:
 *   sincos(+-0) = (+-0, 1); sincos(+-Inf) = (NaN, NaN); NaN propagates
 * Accuracy / algorithm:
 *   sin_cos_impl, identical to separate sin()/cos() calls but with one
 *   reduction
 *============================================================================*/
void ASM_MATH(sincos)(double x, double *sinp, double *cosp)
{
    sin_cos_impl(x, sinp, cosp);
}

/*==============================================================================
 * double ASM_MATH(tan)(double x)
 *------------------------------------------------------------------------------
 * Tangent of x, in radians.
 *
 * Parameters:
 *   x (double) - angle in radians, any magnitude (reduced internally)
 * Returns:
 *   tan(x); tan(+-0) = +-0 and tan(+-Inf) = NaN
 * Special cases:
 *   NaN propagates; |x| < 2^-27 returns x directly (also gives tan(+-0));
 *   |x| <= pi/4 uses the kernel with iy = 1
 * Accuracy / algorithm:
 *   rem_pio2 + kernel_tan; the reduction multiple sets
 *   iy = 1 - (n & 1)*2, so odd quadrants take the reciprocal branch; faithful
 *   (< 1 ulp)
 *============================================================================*/
double ASM_MATH(tan)(double x)
{
    double y[2], z = 0.0;
    int32_t hx, ix, n;

    hx = hi_word(x);
    ix = hx & 0x7fffffff;

    /* ---- special-case dispatch: tiny |x| and the direct kernel band ---- */
    if (ix <= 0x3fe921fb) {                         /* |x| <= pi/4 */
        if (ix < 0x3e400000)                        /* |x| < 2^-27 */
            return x;                               /* also tan(+-0) = +-0 */
        return kernel_tan(x, z, 1);                 /* y is zero in this band */
    }
    /* ---- non-finite arguments: quiet NaN ---- */
    if (ix >= 0x7ff00000)                           /* Inf or NaN */
        return x - x;

    /* ---- reduce, then select the reciprocal branch from n's parity ---- */
    n = rem_pio2(x, y);
    return kernel_tan(y[0], y[1], 1 - ((n & 1) << 1));
}
