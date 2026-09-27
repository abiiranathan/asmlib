/*==============================================================================
 * test_math_arith.c - differential tests for arith.c (fmod, remainder)
 *------------------------------------------------------------------------------
 * fmod and remainder are exact, so every result must match the host libm
 * bit-for-bit. We run a table of IEEE-754 special values and exact tie ratios
 * (odd multiples of y/2) through all pairs, plus 60,000 random pairs, and also
 * verify the sign of zero results (mt_ulp treats +0 and -0 as equal).
 *============================================================================*/

#include "math_test.h"

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 0.25, -0.25, 0.75, -0.75,
    1.5, -1.5, 2.0, -2.0, 2.5, -2.5, 3.0, -3.0, 3.5, -3.5,
    4.0, -4.0, 5.0, -5.0, 5.5, -5.5, 6.0, -6.0, 8.0, -8.0,
    DBL_MIN, -DBL_MIN, DBL_MAX, -DBL_MAX,
    1e300, -1e300, 1e-300, -1e-300, 1e16, -1e16, 1e-16, -1e-16,
    4503599627370496.0, -4503599627370496.0,     /* 2^52 */
    9007199254740992.0, -9007199254740992.0,     /* 2^53 */
    0x1p-1022, -0x1p-1022, 0x1p-1074, -0x1p-1074,
    0x1p-1000, -0x1p-1000, 0x1p1023, -0x1p1023,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

#define U2(fn, x, y) mt_cmp(#fn, (x), ASM_MATH(fn)(x, y), fn(x, y), 0)

/* mt_ulp collapses +0 and -0; check the raw bits when a zero is expected. */
static void check_zero_sign(const char *name, double x, double got, double want)
{
    if (want == 0.0) {
        union { double f; uint64_t u; } a, b;
        a.f = got;
        b.f = want;
        mt_check(a.u == b.u, name, x, got, want, 0);
    }
}

static void test_specials(void)
{
    for (int i = 0; i < NSPEC; i++) {
        for (int j = 0; j < NSPEC; j++) {
            double x = SPECIALS[i], y = SPECIALS[j];
            U2(fmod, x, y);
            U2(remainder, x, y);
            check_zero_sign("fmod", x, ASM_MATH(fmod)(x, y), fmod(x, y));
            check_zero_sign("remainder", x, ASM_MATH(remainder)(x, y),
                            remainder(x, y));
        }
    }
}

/* Exact ties: x = (2k+1) * y/2, all products representable for these y. */
static void test_ties(void)
{
    for (int e = -5; e <= 5; e++) {
        double y = ldexp(1.0, e);
        for (int k = 0; k < 64; k++) {
            double x = (2.0 * (double)k + 1.0) * (y * 0.5);
            U2(fmod, x, y);
            U2(fmod, -x, y);
            U2(fmod, x, -y);
            U2(remainder, x, y);
            U2(remainder, -x, y);
            U2(remainder, x, -y);
            U2(remainder, -x, -y);
        }
    }
}

static void test_random(void)
{
    for (int k = 0; k < 60000; k++) {
        double x = mt_rand_bits();
        double y = mt_rand_bits();
        U2(fmod, x, y);
        U2(remainder, x, y);
        check_zero_sign("fmod", x, ASM_MATH(fmod)(x, y), fmod(x, y));
        check_zero_sign("remainder", x, ASM_MATH(remainder)(x, y),
                        remainder(x, y));
    }
}

int main(void)
{
    printf("== asmlib math: arith ==\n");
    test_specials();
    printf("   specials done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_ties();
    printf("   ties     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random();
    printf("   random   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("arith");
}
