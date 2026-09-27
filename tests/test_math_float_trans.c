/*==============================================================================
 * test_math_float_trans.c - differential tests for float_trans.c
 *------------------------------------------------------------------------------
 * Compares the single-precision transcendental wrappers against the host libm
 * float routines over a table of IEEE-754 special values (including signed
 * zeros, the float limits, subnormals and non-finite values) and a large body
 * of random inputs (bit patterns plus uniform ranges). A faithful result may
 * differ from the reference by at most 1 ULP; erfc allows 2 (the underlying
 * double erfc is itself ~1.5 ulp) and tgamma/lgamma are compared with a
 * relative tolerance of 1e-6, matching the double-precision tests.
 *
 * sincosf is additionally required to agree bit-for-bit with sinf/cosf.
 *============================================================================*/

#include "math_test.h"

static const float FSPECIALS[] = {
    0.0f, -0.0f, 1.0f, -1.0f, 0.5f, -0.5f, 2.0f, -2.0f,
    3.0f, -3.0f, 0.25f, -0.25f, 6.5f, -6.5f,
    FLT_MAX, -FLT_MAX, FLT_MIN, -FLT_MIN,
    0x1p-149f, -0x1p-149f, 0x1p-148f, -0x1p-148f,
    0x1p-126f, -0x1p-126f, 0x1p-100f, -0x1p-100f,
    1024.0f, -1024.0f, INFINITY, -INFINITY, NAN
};
#define NFSPEC ((int)(sizeof FSPECIALS / sizeof FSPECIALS[0]))

/* ---- binary32 ULP distance (the harness helpers work on doubles only) ---- */

static MT_UNUSED uint32_t f32_ord(float x)
{
    union { float f; uint32_t u; } v;
    v.f = x;
    if (v.u >> 31)
        return ~v.u + 1u;                           /* negatives ascend */
    return v.u | 0x80000000u;
}

/* ULP distance between two floats; NaN==NaN counts as 0, NaN vs number as a
 * sentinel that the harness reports as a failure and does not track. */
static MT_UNUSED uint64_t f32_ulp(float a, float b)
{
    if (isnan(a) && isnan(b))
        return 0;
    if (isnan(a) || isnan(b))
        return UINT64_MAX / 2;
    if (a == b)
        return 0;                                   /* handles +/-0, inf */
    uint32_t oa = f32_ord(a), ob = f32_ord(b);
    return oa > ob ? oa - ob : ob - oa;
}

static MT_UNUSED void fcheck(const char *what, float x, float got, float want,
                             uint64_t maxulp)
{
    uint64_t u = f32_ulp(got, want);
    mt_check(u <= maxulp, what, (double)x, (double)got, (double)want, u);
}

/* tgammaf/lgammaf: exact for NaN/Inf/zero, otherwise within 1e-6 relative to
 * max(1, |want|); the ULP distance is still reported for the maximum. */
static MT_UNUSED void fgamma(const char *what, float x, float got, float want)
{
    uint64_t u = f32_ulp(got, want);

    if (isnan(want) || isnan(got)) {
        mt_check(isnan(want) && isnan(got), what, (double)x, (double)got,
                 (double)want, isnan(want) && isnan(got) ? 0 : u);
        return;
    }
    if (isinf(want) || isinf(got) || want == 0.0f) {
        mt_check(got == want, what, (double)x, (double)got, (double)want, u);
        return;
    }
    double rel = fabs((double)got - (double)want);
    double mag = fabs((double)want);
    if (mag < 1.0)
        mag = 1.0;
    rel /= mag;
    mt_check(rel <= 1e-6, what, (double)x, (double)got, (double)want, u);
}

#define F1(fn, x, maxu)                                                      \
    fcheck(#fn, (x), ASM_MATH(fn)(x), fn((float)(x)), (maxu))
#define F2(fn, x, y, maxu)                                                   \
    fcheck(#fn, (x), ASM_MATH(fn)(x, y), fn((float)(x), (float)(y)), (maxu))

static MT_UNUSED float frand_bits(void)
{
    union { float f; uint32_t u; } v;
    v.u = (uint32_t)mt_rand64();
    return v.f;
}

static MT_UNUSED float rndf(float lo, float hi)
{
    return (float)((double)lo + ((double)hi - (double)lo) * mt_rand_double());
}

/* ---- special values ---------------------------------------------------- */

static void test_specials(void)
{
    for (int i = 0; i < NFSPEC; i++) {
        float x = FSPECIALS[i];

        F1(expf, x, 1);
        F1(exp2f, x, 1);
        F1(expm1f, x, 1);
        F1(logf, x, 1);
        F1(log2f, x, 1);
        F1(log10f, x, 1);
        F1(log1pf, x, 1);
        F1(sinf, x, 1);
        F1(cosf, x, 1);
        F1(tanf, x, 1);
        F1(asinf, x, 1);
        F1(acosf, x, 1);
        F1(atanf, x, 1);
        F1(sinhf, x, 1);
        F1(coshf, x, 1);
        F1(tanhf, x, 1);
        F1(asinhf, x, 1);
        F1(acoshf, x, 1);
        F1(atanhf, x, 1);
        F1(erff, x, 1);
        F1(erfcf, x, 2);
        fgamma("tgammaf", x, ASM_MATH(tgammaf)(x), tgammaf(x));
        fgamma("lgammaf", x, ASM_MATH(lgammaf)(x), lgammaf(x));
    }

    /* binary specials: the full cross product */
    for (int i = 0; i < NFSPEC; i++) {
        for (int j = 0; j < NFSPEC; j++) {
            F2(powf, FSPECIALS[i], FSPECIALS[j], 1);
            F2(atan2f, FSPECIALS[i], FSPECIALS[j], 1);
        }
    }
}

/* ---- sincosf: must match sinf/cosf bit-for-bit ------------------------- */

static void check_sincos(float x)
{
    float s, c;
    ASM_MATH(sincosf)(x, &s, &c);
    mt_check(f32_ulp(s, ASM_MATH(sinf)(x)) == 0, "sincosf-sin", (double)x,
             (double)s, (double)ASM_MATH(sinf)(x), 0);
    mt_check(f32_ulp(c, ASM_MATH(cosf)(x)) == 0, "sincosf-cos", (double)x,
             (double)c, (double)ASM_MATH(cosf)(x), 0);
    F1(sinf, x, 1);
    F1(cosf, x, 1);
}

static void test_sincos(void)
{
    float s, c;

    ASM_MATH(sincosf)(0.0f, &s, &c);
    mt_check(s == 0.0f && !signbit(s) && c == 1.0f, "sincosf(+0)", 0.0,
             (double)s, (double)c, 0);
    ASM_MATH(sincosf)(-0.0f, &s, &c);
    mt_check(s == 0.0f && signbit(s) && c == 1.0f, "sincosf(-0)", -0.0,
             (double)s, (double)c, 0);
    ASM_MATH(sincosf)(INFINITY, &s, &c);
    mt_check(isnan(s) && isnan(c), "sincosf(+inf)", INFINITY, (double)s,
             (double)c, 0);
    ASM_MATH(sincosf)(-INFINITY, &s, &c);
    mt_check(isnan(s) && isnan(c), "sincosf(-inf)", -INFINITY, (double)s,
             (double)c, 0);
    ASM_MATH(sincosf)(NAN, &s, &c);
    mt_check(isnan(s) && isnan(c), "sincosf(nan)", NAN, (double)s, (double)c, 0);

    for (int i = 0; i < NFSPEC; i++)
        check_sincos(FSPECIALS[i]);
    for (int k = 0; k < 120000; k++)
        check_sincos(rndf(-1e6f, 1e6f));
}

/* ---- random bit patterns ----------------------------------------------- */

static void test_random_bits(void)
{
    for (int k = 0; k < 120000; k++) {
        float x = frand_bits();
        float y = frand_bits();

        F1(expf, x, 1);
        F1(exp2f, x, 1);
        F1(expm1f, x, 1);
        F1(logf, x, 1);
        F1(log2f, x, 1);
        F1(log10f, x, 1);
        F1(log1pf, x, 1);
        F1(sinf, x, 1);
        F1(cosf, x, 1);
        F1(tanf, x, 1);
        F1(asinf, x, 1);
        F1(acosf, x, 1);
        F1(atanf, x, 1);
        F2(atan2f, x, y, 1);
        F1(sinhf, x, 1);
        F1(coshf, x, 1);
        F1(tanhf, x, 1);
        F1(asinhf, x, 1);
        F1(acoshf, x, 1);
        F1(atanhf, x, 1);
        F1(erff, x, 1);
        F1(erfcf, x, 2);
        F2(powf, x, y, 1);
        fgamma("tgammaf", x, ASM_MATH(tgammaf)(x), tgammaf(x));
        fgamma("lgammaf", x, ASM_MATH(lgammaf)(x), lgammaf(x));
    }
}

/* ---- uniform ranges ---------------------------------------------------- */

static void test_uniform(void)
{
    for (int k = 0; k < 60000; k++) {
        float x = rndf(-100.0f, 100.0f);
        F1(expf, x, 1);
        F1(expm1f, x, 1);
        F1(sinhf, x, 1);
        F1(coshf, x, 1);
        F1(tanhf, x, 1);

        x = rndf(-200.0f, 200.0f);
        F1(exp2f, x, 1);

        x = rndf(FLT_MIN, 1e6f);
        F1(logf, x, 1);
        F1(log2f, x, 1);
        F1(log10f, x, 1);
        F1(log1pf, x, 1);

        x = rndf(-0.9999f, 1e6f);
        F1(log1pf, x, 1);

        x = rndf(-6.0f, 6.0f);
        F1(erff, x, 1);
        F1(erfcf, x, 2);

        x = rndf(-1.0f, 1.0f);
        F1(asinf, x, 1);
        F1(acosf, x, 1);
        F1(atanhf, x, 1);

        x = rndf(1.0f, 1e6f);
        F1(acoshf, x, 1);

        x = rndf(-1e6f, 1e6f);
        F1(asinhf, x, 1);
        F1(atanf, x, 1);
    }

    /* trig over wide and huge arguments, plus powf over positive bases */
    for (int k = 0; k < 60000; k++) {
        float x = rndf(-1e6f, 1e6f);
        F1(sinf, x, 1);
        F1(cosf, x, 1);
        F1(tanf, x, 1);

        x = (mt_rand_double() * 2.0 - 1.0) * 1e30f;
        F1(sinf, x, 1);
        F1(cosf, x, 1);
        F1(tanf, x, 1);

        float b = rndf(FLT_MIN, 1e3f);
        float e = rndf(-30.0f, 30.0f);
        F2(powf, b, e, 1);
        F2(atan2f, x, b, 1);
    }

    /* gamma functions over their interesting ranges */
    for (int k = 0; k < 60000; k++) {
        float x = rndf(0.01f, 30.0f);
        fgamma("tgammaf", x, ASM_MATH(tgammaf)(x), tgammaf(x));
        fgamma("lgammaf", x, ASM_MATH(lgammaf)(x), lgammaf(x));

        x = rndf(-30.0f, -0.01f);
        fgamma("tgammaf", x, ASM_MATH(tgammaf)(x), tgammaf(x));
        fgamma("lgammaf", x, ASM_MATH(lgammaf)(x), lgammaf(x));
    }
}

int main(void)
{
    printf("== asmlib math: float transcendental ==\n");
    test_specials();
    printf("   specials done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_sincos();
    printf("   sincos   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random_bits();
    printf("   bits     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_uniform();
    printf("   uniform  done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("float_trans");
}
