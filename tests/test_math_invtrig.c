/*==============================================================================
 * test_math_invtrig.c - differential tests for invtrig.c
 *------------------------------------------------------------------------------
 * Compares asin/acos/atan/atan2 against the host libm over a table of IEEE-754
 * special values (including the neighbourhood of +/-1 where the half-angle
 * reductions switch) and a large body of random inputs. A faithful result is
 * allowed at most 1 ulp.
 *============================================================================*/

#include "math_test.h"

static const double SPECIALS[] = {
    0.0, -0.0,
    1.0, -1.0,
    /* the two doubles closest to 1 from below and above */
    0x1.fffffffffffffp-1, -0x1.fffffffffffffp-1,   /* 1 - 2^-53 */
    0x1.0000000000000p+0, -0x1.0000000000000p+0,
    0x1.0000000000001p+0, -0x1.0000000000001p+0,   /* 1 + 2^-52 */
    0.9999999999999999, -0.9999999999999999,
    0.5, -0.5, 0.5000000000000001, -0.5000000000000001,
    0.25, -0.25, 0.75, -0.75,
    0x1p-1074, -0x1p-1074,                          /* tiny */
    0x1p-1022, -0x1p-1022,                          /* smallest normal */
    0x1p-52, -0x1p-52,
    1e300, -1e300, 1e-300, -1e-300,
    DBL_MIN, -DBL_MIN, DBL_MAX, -DBL_MAX,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

/* A smaller table for the (y,x) argument pairs of atan2, deliberately
 * containing zeros, infinities and NaN. */
static const double PAIRS[] = {
    0.0, -0.0, 1.0, -1.0, 2.0, -2.0,
    0.5, -0.5, 1e300, -1e300, 1e-300, -1e-300,
    0x1p-1074, -0x1p-1074, DBL_MAX, -DBL_MAX, DBL_MIN, -DBL_MIN,
    INFINITY, -INFINITY, NAN
};
#define NPAIR ((int)(sizeof PAIRS / sizeof PAIRS[0]))

#define U1(fn, x)    mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), 1)
#define U2(fn, x, y) mt_cmp(#fn, (x), ASM_MATH(fn)(x, y), fn(x, y), 1)

static void test_asin(void)
{
    for (int i = 0; i < NSPEC; i++)
        U1(asin, SPECIALS[i]);

    /* Uniform [-1,1]. */
    for (int i = 0; i < 60000; i++) {
        double x = mt_rand_double() * 2.0 - 1.0;
        U1(asin, x);
    }

    /* Squeeze up against +/-1 from below: the half-angle branch. */
    for (int i = 0; i < 20000; i++) {
        double eps = mt_rand_double() * 1e-3;
        double x = (mt_rand64() & 1) ? 1.0 - eps : eps - 1.0;
        U1(asin, x);
    }
}

static void test_acos(void)
{
    for (int i = 0; i < NSPEC; i++)
        U1(acos, SPECIALS[i]);

    for (int i = 0; i < 60000; i++) {
        double x = mt_rand_double() * 2.0 - 1.0;
        U1(acos, x);
    }

    for (int i = 0; i < 20000; i++) {
        double eps = mt_rand_double() * 1e-3;
        double x = (mt_rand64() & 1) ? 1.0 - eps : eps - 1.0;
        U1(acos, x);
    }
}

static void test_atan(void)
{
    for (int i = 0; i < NSPEC; i++)
        U1(atan, SPECIALS[i]);

    /* Uniform [-1e8, 1e8]: exercises every reduction band. */
    for (int i = 0; i < 40000; i++) {
        double x = (mt_rand_double() * 2.0 - 1.0) * 1e8;
        U1(atan, x);
    }

    /* Arbitrary finite bit patterns: tiny, huge and everything between. */
    for (int i = 0; i < 40000; i++) {
        double x = mt_rand_bits();
        U1(atan, x);
    }
}

static void test_atan2(void)
{
    for (int i = 0; i < NPAIR; i++)
        for (int j = 0; j < NPAIR; j++)
            U2(atan2, PAIRS[i], PAIRS[j]);

    /* Random (y,x) in the unit square including a fair share of exact zeros. */
    for (int i = 0; i < 40000; i++) {
        double y = mt_rand_double() * 2.0 - 1.0;
        double x = mt_rand_double() * 2.0 - 1.0;
        if ((mt_rand64() & 7) == 0)
            y = 0.0;
        if ((mt_rand64() & 7) == 0)
            x = 0.0;
        U2(atan2, y, x);
    }

    /* Arbitrary bit patterns for both arguments. */
    for (int i = 0; i < 30000; i++) {
        double y = mt_rand_bits();
        double x = mt_rand_bits();
        U2(atan2, y, x);
    }

    /* Wide-magnitude pairs: the |y/x| > 2^60 and < 2^-60 shortcuts. */
    for (int i = 0; i < 20000; i++) {
        double y = (mt_rand_double() * 2.0 - 1.0) * 1e300;
        double x = (mt_rand_double() * 2.0 - 1.0) * 1e-300;
        U2(atan2, y, x);
        U2(atan2, x, y);
    }
}

int main(void)
{
    printf("== asmlib math: invtrig ==\n");
    test_asin();
    printf("   asin   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_acos();
    printf("   acos   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_atan();
    printf("   atan   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_atan2();
    printf("   atan2  done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("invtrig");
}
