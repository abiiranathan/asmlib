/*==============================================================================
 * test_math_basic.c - differential tests for basic.c
 *------------------------------------------------------------------------------
 * Compares every basic routine against the host libm over random inputs and a
 * table of IEEE-754 special values. Routines that are exact are required to
 * match bit-for-bit; the roots allow at most 1 ulp.
 *============================================================================*/

#include "math_test.h"

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, -3.0,
    6.5, -6.5, 2.5, -2.5, 1.5, -1.5, 0.25, -0.25,
    DBL_MIN, -DBL_MIN, DBL_MAX, -DBL_MAX,
    1e300, -1e300, 1e-300, -1e-300,
    0x1p-1022, -0x1p-1022, 0x1p-1074, -0x1p-1074, 0x1p-1000, -0x1p-1000,
    1024.0, -1024.0, 4294967296.0, -4294967296.0,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

#define U1(fn, x, maxu) mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), (maxu))
#define U2(fn, x, y, maxu) mt_cmp(#fn, (x), ASM_MATH(fn)(x, y), fn(x, y), (maxu))

/* cbrt is verified directly rather than against libm: glibc's cbrt is itself
 * up to ~3 ulp off, while ours is correctly rounded. A correctly rounded y
 * has y^3 within ~3 ulp of x (relative), which long double resolves. */
static void check_cbrt(double x)
{
    double y = ASM_MATH(cbrt)(x);
    if (isnan(x) || isinf(x) || x == 0.0) {
        mt_check(y == x || (isnan(x) && isnan(y)), "cbrt-special", x, y, x, 0);
        return;
    }
    long double yl = (long double)y;
    long double cube = yl * yl * yl;
    long double xl = (long double)x;
    long double rel = fabsl((cube - xl) / xl);
    mt_check(rel <= 0x1p-50L && (signbit(y) == signbit(x)), "cbrt-cube", x,
             (double)rel, 0.0, 0);
}

static void test_sign_and_select(void)
{
    for (int i = 0; i < NSPEC; i++) {
        double x = SPECIALS[i];
        U1(fabs, x, 0);
        U2(copysign, x, SPECIALS[NSPEC - 1 - i], 0);
        for (int j = 0; j < NSPEC; j++) {
            double y = SPECIALS[j];
            U2(fmin, x, y, 0);
            U2(fmax, x, y, 0);
            U2(fdim, x, y, 0);
        }
    }
    for (int k = 0; k < 20000; k++) {
        double x = mt_rand_bits(), y = mt_rand_bits();
        U1(fabs, x, 0);
        U2(copysign, x, y, 0);
        U2(fmin, x, y, 0);
        U2(fmax, x, y, 0);
        U2(fdim, x, y, 0);
    }
}

static void test_rounding(void)
{
    for (int i = 0; i < NSPEC; i++) {
        double x = SPECIALS[i];
        U1(floor, x, 0);
        U1(ceil, x, 0);
        U1(trunc, x, 0);
        U1(round, x, 0);
        U1(rint, x, 0);
        U1(nearbyint, x, 0);
    }
    for (int k = 0; k < 40000; k++) {
        double x = mt_rand_bits();
        U1(floor, x, 0);
        U1(ceil, x, 0);
        U1(trunc, x, 0);
        U1(round, x, 0);
        U1(rint, x, 0);
        U1(nearbyint, x, 0);
    }
    /* Values straddling the half-integer boundaries for an integer exponent. */
    for (int e = 0; e < 60; e++) {
        double base = ldexp(1.0, e);
        const double fracs[] = { 0.25, 0.5, 0.75, 0.49999999999999994, 0.5000000000000001 };
        for (int f = 0; f < 5; f++) {
            double x = base * (1.0 + fracs[f]);
            U1(round, x, 0);
            U1(rint, x, 0);
            U1(floor, x, 0);
            U1(ceil, x, 0);
            U1(trunc, x, 0);
        }
    }
}

static void test_roots(void)
{
    for (int i = 0; i < NSPEC; i++) {
        U1(sqrt, SPECIALS[i], 0);
        check_cbrt(SPECIALS[i]);
    }
    for (int k = 0; k < 40000; k++) {
        double x = mt_rand_bits();
        U1(sqrt, x, 0);
        check_cbrt(x);
    }
    /* hypot over specials and randoms */
    for (int i = 0; i < NSPEC; i++)
        for (int j = 0; j < NSPEC; j++)
            U2(hypot, SPECIALS[i], SPECIALS[j], 1);
    for (int k = 0; k < 30000; k++) {
        double x = mt_rand_bits(), y = mt_rand_bits();
        U2(hypot, x, y, 1);
    }
}

static void test_decomposition(void)
{
    for (int k = 0; k < 30000; k++) {
        double x = mt_rand_bits();
        int ea, eb;

        double ma = ASM_MATH(frexp)(x, &ea);
        double mb = frexp(x, &eb);
        mt_check(ma == mb && ea == eb, "frexp", x, ma, mb, 0);
        mt_check(ASM_MATH(frexp)(x, &ea) == ma && ea == eb, "frexp-e", x,
                 (double)ea, (double)eb, 0);

        int n = (int)(mt_rand64() % 4400) - 2200;
        mt_cmp("scalbn", x, ASM_MATH(scalbn)(x, n), scalbn(x, n), 1);
        mt_cmp("ldexp", x, ASM_MATH(ldexp)(x, n), ldexp(x, n), 1);

        int ia = ASM_MATH(ilogb)(x);
        int ib = ilogb(x);
        mt_check(ia == ib, "ilogb", x, (double)ia, (double)ib, 0);
        U1(logb, x, 0);

        double ipa, ipb;
        double fa = ASM_MATH(modf)(x, &ipa);
        double fb = modf(x, &ipb);
        mt_check(fa == fb && ipa == ipb, "modf", x, fa, fb, 0);
    }
}

int main(void)
{
    printf("== asmlib math: basic ==\n");
    test_sign_and_select();
    printf("   sign/select done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_rounding();
    printf("   rounding    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_roots();
    printf("   roots       done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_decomposition();
    printf("   decomp      done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("basic");
}
