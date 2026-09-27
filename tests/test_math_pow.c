/*==============================================================================
 * test_math_pow.c - differential tests for pow.c
 *------------------------------------------------------------------------------
 * Compares asm_pow against the host libm over the complete IEEE-754 special
 * value table (including negative bases with integral, half-integral and
 * non-integral exponents), a sweep of the overflow/underflow boundaries, and
 * well over 100,000 random cases built from random bit patterns, uniformly
 * distributed positive bases and a mix of fixed, huge, tiny and random
 * exponents. Every result must be within 1 ulp of the reference.
 *============================================================================*/

#include "math_test.h"

#define U2(x,y) mt_cmp("pow",(x),ASM_MATH(pow)(x,y),pow(x,y),1)

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 0.5, -0.5, 3.0, -3.0,
    2.5, -2.5, 1.5, -1.5, 4.0, -4.0, 0.25, -0.25, 8.0, -8.0,
    0.9999999999999999, 1.0000000000000002,
    -0.9999999999999999, -1.0000000000000002,
    DBL_MIN, -DBL_MIN, DBL_MAX, -DBL_MAX,
    1e300, -1e300, 1e-300, -1e-300,
    0x1p-1022, -0x1p-1022, 0x1p-1074, -0x1p-1074,
    0x1p-1000, -0x1p-1000, 1024.0, -1024.0, 1e16, -1e16,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

static const double EXPS[] = {
    -3.0, -2.0, -1.5, -1.0, -0.5, -0.25, 0.0, 0.25, 0.5, 1.0,
    1.5, 2.0, 3.0, 4.0, 1023.0, 1024.0, -1073.0, -1074.0, -1075.0,
    1e300, -1e300, 1e-300, -1e-300, 1e16, -1e16,
    INFINITY, -INFINITY, NAN
};
#define NEXP ((int)(sizeof EXPS / sizeof EXPS[0]))

/* Full cross product of the special tables. */
static void test_specials(void)
{
    for (int i = 0; i < NSPEC; i++)
        for (int j = 0; j < NEXP; j++)
            U2(SPECIALS[i], EXPS[j]);
}

/* Negative bases against integral / half-integral / non-integral exponents:
 * the sign is exercised on the first group and NaN on the last. */
static void test_parity(void)
{
    static const double bases[] = {
        -2.0, -3.0, -4.0, -8.0, -0.5, -0.25, -1.0000000000000002,
        -0.9999999999999999, -1e300, -1e-300
    };
    static const double exps[] = {
        -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 99.0, 100.0,
        0.5, -0.5, 1.5, 2.5, -2.5, 1e-300, 1e300,
        9007199254740992.0, 9007199254740994.0
    };
    for (int i = 0; i < (int)(sizeof bases / sizeof bases[0]); i++)
        for (int j = 0; j < (int)(sizeof exps / sizeof exps[0]); j++)
            U2(bases[i], exps[j]);
}

/* Neighbours of the overflow/underflow thresholds and of |x| = 1. */
static void test_edges(void)
{
    static const double bases[] = { 0.5, 2.0, 1.0 / 3.0, 3.0, 10.0,
                                    -2.0, -0.5, 1.0000000000000002 };
    static const double lvls[] = { 1023.0, 1024.0, -1073.0, -1074.0, -1075.0 };
    for (int i = 0; i < (int)(sizeof bases / sizeof bases[0]); i++) {
        for (int j = 0; j < (int)(sizeof lvls / sizeof lvls[0]); j++) {
            for (int d = -2; d <= 2; d++) {
                double y = lvls[j];
                for (int s = 0; s < (d < 0 ? -d : d); s++)
                    y = nextafter(y, d > 0 ? INFINITY : -INFINITY);
                U2(bases[i], y);
            }
        }
    }
}

/* Deterministic mixture of representative exponents. */
static double pick_exp(int k)
{
    switch (k % 13) {
    case 0:  return -3.0;
    case 1:  return -2.0;
    case 2:  return -0.5;
    case 3:  return 0.0;
    case 4:  return 0.5;
    case 5:  return 1.0;
    case 6:  return 2.0;
    case 7:  return 3.0;
    case 8:  return 1e300;
    case 9:  return -1e300;
    case 10: return 1e-300;
    case 11: return -1e-300;
    default: return (mt_rand_double() * 2.0 - 1.0) * 1e3;
    }
}

static void test_random(void)
{
    /* Random bit patterns for both arguments. */
    for (int k = 0; k < 50000; k++) {
        double x = mt_rand_bits();
        double y = mt_rand_bits();
        U2(x, y);
    }

    /* Random bases (both signs) with the mixed exponent set. y is bound to a
     * variable because U2 expands its argument twice. */
    for (int k = 0; k < 40000; k++) {
        double x = mt_rand_bits();
        double y = pick_exp(k);
        U2(x, y);
    }

    /* Uniform positive bases in (0, 1e6) with the mixed exponent set. */
    for (int k = 0; k < 40000; k++) {
        double x = mt_rand_double() * 1e6 + DBL_MIN;
        double y = pick_exp(k);
        U2(x, y);
    }

    /* Uniform bases near 1 (the hard regime for the logarithm). */
    for (int k = 0; k < 20000; k++) {
        double x = 1.0 + mt_rand_double() * 1e-6;
        double y = pick_exp(k);
        U2(x, y);
        y = pick_exp(k + 1);
        U2(1.0 / x, y);
    }
}

int main(void)
{
    printf("== asmlib math: pow ==\n");
    test_specials();
    printf("   specials done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_parity();
    printf("   parity   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_edges();
    printf("   edges    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random();
    printf("   random   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("pow");
}
