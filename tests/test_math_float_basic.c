/*==============================================================================
 * test_math_float_basic.c - differential tests for float_basic.c
 *------------------------------------------------------------------------------
 * Compares every binary32 routine against the host libm over a table of
 * IEEE-754 special values, 160k random bit patterns and 80k small-magnitude
 * values. Exact routines must agree bit-for-bit (NaN counts as equal to NaN);
 * the roots and the select/difference routines allow at most 1 ulp.
 *============================================================================*/

#include "math_test.h"
#include <limits.h>

static inline uint32_t fbits(float x)
{
    union { float f; uint32_t u; } v = { x };
    return v.u;
}

static inline float bitsf(uint32_t u)
{
    union { float f; uint32_t u; } v;
    v.u = u;
    return v.f;
}

static const float FSPECIALS[] = {
    0.0f, -0.0f,
    1.0f, -1.0f, 0.5f, -0.5f, 2.0f, -2.0f, 3.0f, -3.0f,
    0.25f, -0.25f, 0.75f, -0.75f, 1.5f, -1.5f, 2.5f, -2.5f,
    6.5f, -6.5f, 0.1f, -0.1f,
    FLT_MAX, -FLT_MAX, FLT_MIN, -FLT_MIN, FLT_EPSILON, -FLT_EPSILON,
    0x1p-149f, -0x1p-149f,                      /* smallest subnormal   */
    0x1p-148f, -0x1p-148f,                      /* 2 * smallest subnorm */
    0x1.fffffep-127f, -0x1.fffffep-127f,        /* largest subnormal    */
    0x1p-126f, -0x1p-126f,                      /* smallest normal      */
    0x1p-127f, -0x1p-127f,
    8388608.0f, -8388608.0f,                    /* 2^23                 */
    16777215.0f, -16777215.0f,
    16777216.0f, -16777216.0f,                  /* 2^24                 */
    4294967296.0f, -4294967296.0f,
    1e30f, -1e30f, 1e-30f, -1e-30f,
    1e38f, -1e38f, 1e-38f, -1e-38f,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof FSPECIALS / sizeof FSPECIALS[0]))

/* Bit-exact comparison, treating any NaN as equal to any NaN. */
static void eqf(const char *what, float x, float got, float want)
{
    int ok;
    if (isnan(want) || isnan(got))
        ok = isnan(want) && isnan(got);
    else
        ok = fbits(got) == fbits(want);
    mt_check(ok, what, (double)x, (double)got, (double)want, 0);
}

static void ulf(const char *what, float x, float got, float want, uint64_t maxu)
{
    /* got and want are already floats, but the host libm function returns a
     * value that may be promoted to double with extra precision on some
     * targets (e.g. when contracted). Round both to float first, then compare
     * with the double-ULP metric, so the distance is measured in binary32
     * ulps rather than in the binary64 grid the promotions live on. */
    float g = (float)got;
    float w = (float)want;
    mt_cmp(what, (double)x, (double)g, (double)w, maxu);
}

#define E1(fn, x)          eqf(#fn, (x), ASM_MATH(fn)(x), fn(x))
#define U1(fn, x, maxu)    ulf(#fn, (x), ASM_MATH(fn)(x), fn(x), (maxu))
#define E2(fn, x, y)       eqf(#fn, (x), ASM_MATH(fn)(x, y), fn(x, y))
#define U2(fn, x, y, maxu) ulf(#fn, (x), ASM_MATH(fn)(x, y), fn(x, y), (maxu))

static float rnd_bits(void)
{
    uint32_t u = (uint32_t)mt_rand64();
    /* Quiet any NaN so signaling-NaN semantics (which differ between libms)
     * do not contaminate the comparison; Inf is left untouched. */
    if ((u & 0x7f800000u) == 0x7f800000u && (u & 0x007fffffu))
        u |= 0x00400000u;
    return bitsf(u);
}

static float rnd_small(void)
{
    int v = (int)(mt_rand64() % 2001) - 1000;
    int f = (int)(mt_rand64() % 5);
    return (float)v + (float)f * 0.25f;
}

/* frexpf checks the significand and the returned exponent separately. */
static void check_frexpf(float x)
{
    int ea, eb;
    float ma = ASM_MATH(frexpf)(x, &ea);
    float mb = frexpf(x, &eb);
    eqf("frexpf", x, ma, mb);
    mt_check(ea == eb, "frexpf-e", (double)x, (double)ea, (double)eb, 0);
}

/* modff checks the integral and fractional parts separately. */
static void check_modff(float x)
{
    float ipa, ipb;
    float fa = ASM_MATH(modff)(x, &ipa);
    float fb = modff(x, &ipb);
    eqf("modff-frac", x, fa, fb);
    eqf("modff-int", x, ipa, ipb);
}

static void check_ilogbf(float x)
{
    int a = ASM_MATH(ilogbf)(x), b = ilogbf(x);
    mt_check(a == b, "ilogbf", (double)x, (double)a, (double)b, 0);
}

static void check_remquof(float x, float y)
{
    int qa = 0, qb = 0;
    float ra = ASM_MATH(remquof)(x, y, &qa);
    float rb = remquof(x, y, &qb);
    eqf("remquof", x, ra, rb);
    /* *quo is unspecified for the invalid cases (y==0, NaN, x=Inf/NaN), where
     * the host may not write it at all.  Otherwise the standard only fixes the
     * quotient modulo 2^n (n >= 3) and its sign, so compare the low three bits
     * of the magnitude (zero has no meaningful sign). */
    if (isnan(ra))
        return;
    {
        unsigned ma = (unsigned)(qa < 0 ? -(unsigned)qa : (unsigned)qa) % 8u;
        unsigned mb = (unsigned)(qb < 0 ? -(unsigned)qb : (unsigned)qb) % 8u;
        int sa = (qa > 0) - (qa < 0), sb = (qb > 0) - (qb < 0);
        mt_check(ma == mb && (ma == 0 || sa == sb), "remquof-q", (double)x,
                 (double)qa, (double)qb, 0);
    }
}

static void check_scalef(float x, int n)
{
    eqf("ldexpf", x, ASM_MATH(ldexpf)(x, n), ldexpf(x, n));
    eqf("scalbnf", x, ASM_MATH(scalbnf)(x, n), scalbnf(x, n));
}

static void check_int_round(float x)
{
    mt_check(ASM_MATH(lrintf)(x) == lrintf(x), "lrintf", (double)x,
             (double)ASM_MATH(lrintf)(x), (double)lrintf(x), 0);
    mt_check(ASM_MATH(llrintf)(x) == llrintf(x), "llrintf", (double)x,
             (double)ASM_MATH(llrintf)(x), (double)llrintf(x), 0);
    mt_check(ASM_MATH(lroundf)(x) == lroundf(x), "lroundf", (double)x,
             (double)ASM_MATH(lroundf)(x), (double)lroundf(x), 0);
    mt_check(ASM_MATH(llroundf)(x) == llroundf(x), "llroundf", (double)x,
             (double)ASM_MATH(llroundf)(x), (double)llroundf(x), 0);
}

static void check_fmaf(float x, float y, float z)
{
    float got = ASM_MATH(fmaf)(x, y, z);
    float want = fmaf(x, y, z);
    eqf("fmaf", x, got, want);
}

static void test_sign_and_select(void)
{
    int i, j;
    for (i = 0; i < NSPEC; i++) {
        float x = FSPECIALS[i];
        E1(fabsf, x);
        for (j = 0; j < NSPEC; j++) {
            float y = FSPECIALS[j];
            E2(copysignf, x, y);
            U2(fminf, x, y, 1);
            U2(fmaxf, x, y, 1);
            U2(fdimf, x, y, 1);
        }
    }
    for (i = 0; i < 160000; i++) {
        float x = rnd_bits(), y = rnd_bits();
        E1(fabsf, x);
        E2(copysignf, x, y);
        U2(fminf, x, y, 1);
        U2(fmaxf, x, y, 1);
        U2(fdimf, x, y, 1);
    }
}

static void test_rounding(void)
{
    int i, k, e, f;
    static const float FRACS[] = {
        0.25f, 0.5f, 0.75f, 0.49999997f, 0.50000006f, -0.25f, -0.5f, -0.75f
    };
    for (i = 0; i < NSPEC; i++) {
        float x = FSPECIALS[i];
        E1(floorf, x);
        E1(ceilf, x);
        E1(truncf, x);
        E1(rintf, x);
        E1(nearbyintf, x);
        U1(roundf, x, 1);
    }
    for (k = -1000; k <= 1000; k++) {
        float base = (float)k;
        float xs[4];
        xs[0] = base + 0.5f;
        xs[1] = base - 0.5f;
        xs[2] = base + 0.25f;
        xs[3] = base + 0.75f;
        for (f = 0; f < 4; f++) {
            E1(floorf, xs[f]);
            E1(ceilf, xs[f]);
            E1(truncf, xs[f]);
            E1(rintf, xs[f]);
            E1(nearbyintf, xs[f]);
            U1(roundf, xs[f], 1);
        }
    }
    for (e = 0; e <= 25; e++) {
        float base = ldexpf(1.0f, e);
        for (f = 0; f < 8; f++) {
            float x = base * (1.0f + FRACS[f]);
            E1(floorf, x);
            E1(ceilf, x);
            E1(truncf, x);
            E1(rintf, x);
            E1(nearbyintf, x);
            U1(roundf, x, 1);
        }
    }
    for (i = 0; i < 160000; i++) {
        float x = rnd_bits();
        E1(floorf, x);
        E1(ceilf, x);
        E1(truncf, x);
        E1(rintf, x);
        E1(nearbyintf, x);
        U1(roundf, x, 1);
    }
}

static void test_decomposition(void)
{
    static const int NS[] = {
        0, 1, -1, 2, -2, 23, -23, 24, -24, 25, -25,
        126, -126, 127, -127, 128, -128, 149, -149, 150, -150,
        -1022, 1023, -1074, INT_MAX, INT_MIN
    };
    int i, k;
    for (i = 0; i < NSPEC; i++) {
        float x = FSPECIALS[i];
        check_frexpf(x);
        check_modff(x);
        check_ilogbf(x);
        E1(logbf, x);
        for (k = 0; k < (int)(sizeof NS / sizeof NS[0]); k++)
            check_scalef(x, NS[k]);
    }
    for (k = 0; k < 80000; k++) {
        float x = (k & 1) ? rnd_bits() : rnd_small();
        int n = (int)(mt_rand64() % 601) - 300;
        check_frexpf(x);
        check_modff(x);
        check_ilogbf(x);
        E1(logbf, x);
        check_scalef(x, n);
    }
}

static void test_arith(void)
{
    int i, j, k;
    for (i = 0; i < NSPEC; i++) {
        float x = FSPECIALS[i];
        U1(sqrtf, x, 1);
        U1(cbrtf, x, 1);
        for (j = 0; j < NSPEC; j++) {
            float y = FSPECIALS[j];
            E2(fmodf, x, y);
            E2(remainderf, x, y);
            check_remquof(x, y);
            U2(hypotf, x, y, 1);
        }
    }
    for (k = 0; k < 160000; k++) {
        float x = rnd_bits(), y = rnd_bits();
        U1(sqrtf, x, 1);
        U1(cbrtf, x, 1);
        E2(fmodf, x, y);
        E2(remainderf, x, y);
        check_remquof(x, y);
        U2(hypotf, x, y, 1);
    }
    /* exact ties at half the divisor */
    for (i = -40; i <= 40; i++) {
        float y = ldexpf(1.0f, i);
        for (j = 0; j < 64; j++) {
            float x = (2.0f * (float)j + 1.0f) * (0.5f * y);
            E2(fmodf, x, y);
            E2(remainderf, x, y);
            check_remquof(x, y);
        }
    }
}

static void test_nextafter_and_fma(void)
{
    int i, j, k;
    for (i = 0; i < NSPEC; i++)
        for (j = 0; j < NSPEC; j++)
            E2(nextafterf, FSPECIALS[i], FSPECIALS[j]);
    for (k = 0; k < 160000; k++) {
        float x = rnd_bits(), y = rnd_bits();
        E2(nextafterf, x, y);
    }

    for (i = 0; i < NSPEC; i++)
        for (j = 0; j < NSPEC; j++)
            for (k = 0; k < NSPEC; k++)
                check_fmaf(FSPECIALS[i], FSPECIALS[j], FSPECIALS[k]);
    for (k = 0; k < 120000; k++)
        check_fmaf(rnd_bits(), rnd_bits(), rnd_bits());
    /* small integers with z near -(x*y) to force exact cancellation */
    for (k = 0; k < 60000; k++) {
        float x = (float)((int)(mt_rand64() % 201) - 100);
        float y = (float)((int)(mt_rand64() % 201) - 100);
        float p = x * y;
        float z;
        switch (mt_rand64() % 4) {
        case 0: z = -p; break;
        case 1: z = -p + (float)((int)(mt_rand64() % 5) - 2); break;
        case 2: z = -p * (1.0f + 0x1p-23f); break;
        default: z = -p - (float)((int)(mt_rand64() % 5) - 2); break;
        }
        check_fmaf(x, y, z);
    }
}

static void test_int_round_and_nan(void)
{
    static const float EXTRA[] = {
        0.5f, -0.5f, 1.5f, -1.5f, 2.5f, -2.5f, 0.49999997f, -0.49999997f,
        0.50000006f, -0.50000006f, 4503599627370496.0f, 9223372036854775808.0f,
        -9223372036854775808.0f, 1e30f, -1e30f, FLT_MAX, -FLT_MAX,
        INFINITY, -INFINITY, NAN
    };
    int i, k;
    float n = ASM_MATH(nanf)("asmlib");
    mt_check(isnan(n), "nanf", 0.0, (double)n, 0.0, 0);
    for (i = 0; i < NSPEC; i++)
        check_int_round(FSPECIALS[i]);
    for (i = 0; i < (int)(sizeof EXTRA / sizeof EXTRA[0]); i++)
        check_int_round(EXTRA[i]);
    for (k = 0; k < 80000; k++) {
        float x = (k & 1) ? rnd_bits() : rnd_small();
        check_int_round(x);
    }
}

int main(void)
{
    printf("== asmlib math: float basic ==\n");
    test_sign_and_select();
    printf("   sign/select done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_rounding();
    printf("   rounding    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_decomposition();
    printf("   decomp      done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_arith();
    printf("   arith       done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_nextafter_and_fma();
    printf("   next/fma    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_int_round_and_nan();
    printf("   int/nan     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("float-basic");
}
