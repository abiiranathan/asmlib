/*==============================================================================
 * test_math_invhyperbolic.c - differential tests for invhyperbolic.c
 *------------------------------------------------------------------------------
 * Compares asm_asinh / asm_acosh / asm_atanh against the host libm over a table
 * of IEEE-754 special and boundary values plus a large body of pseudo-random
 * inputs: uniform values in the natural domains, values assembled from random
 * bits, and tiny magnitudes near (and below) the subnormal threshold. Every
 * result must be within 1 ulp of the reference.
 *============================================================================*/

#include "math_test.h"

#define U1(fn, x) mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), 1)

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0,
    0x1.fffffffffffffp-1,               /* just below 1 */
    0x1.0000000000001p+0,               /* just above 1 */
    0.5, -0.5, 2.0, -2.0,
    INFINITY, -INFINITY, NAN,
    DBL_MAX, -DBL_MAX, DBL_MIN, -DBL_MIN,
    0x1p-1074, -0x1p-1074, 0x1p-1022, -0x1p-1022,
    0x1p-1000, -0x1p-1000,
    1e-300, -1e-300, 1e300, -1e300,
    1e6, -1e6, 100.0, -100.0
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

static void test_specials(void)
{
    for (int i = 0; i < NSPEC; i++) {
        double x = SPECIALS[i];
        U1(asinh, x);
        U1(acosh, x);
        U1(atanh, x);
    }

    /* Values a few ulp either side of +-1 and of 2: the branch boundaries. */
    for (int d = -3; d <= 3; d++) {
        double up = 1.0, dn = 1.0;
        for (int s = 0; s <= (d < 0 ? -d : d); s++) {
            if (d > 0)
                up = nextafter(up, INFINITY);
            if (d < 0)
                dn = nextafter(dn, 0.0);
        }
        U1(acosh, up);
        U1(atanh, up);
        U1(acosh, dn);
        U1(atanh, dn);
        U1(atanh, -up);
        U1(atanh, -dn);

        double two = 2.0;
        for (int s = 0; s < (d < 0 ? -d : d); s++)
            two = nextafter(two, d > 0 ? INFINITY : 0.0);
        U1(asinh, two);
        U1(asinh, -two);
        U1(acosh, two);
    }
}

static void test_uniform(void)
{
    /* asinh/atanh over [-100, 100]; atanh's |x|>1 cases must be NaN. */
    for (int i = 0; i < 30000; i++) {
        double x = (mt_rand_double() * 2.0 - 1.0) * 100.0;
        U1(asinh, x);
        U1(atanh, x);
    }
    /* atanh over its real domain, denser near the singularity. */
    for (int i = 0; i < 20000; i++) {
        double x = mt_rand_double() * 2.0 - 1.0;
        U1(atanh, x);
        U1(asinh, x);
    }
    /* acosh over [1, 1e6]. */
    for (int i = 0; i < 30000; i++) {
        double x = 1.0 + mt_rand_double() * (1e6 - 1.0);
        U1(acosh, x);
    }
}

static void test_random_bits(void)
{
    for (int i = 0; i < 30000; i++) {
        double x = mt_rand_bits();
        U1(asinh, x);
        U1(acosh, x);
        U1(atanh, x);
    }
}

static void test_tiny(void)
{
    for (int i = 0; i < 30000; i++) {
        double s = (mt_rand64() & 1) ? 1.0 : -1.0;
        double x = s * mt_rand_double() * 1e-300;
        U1(asinh, x);
        U1(atanh, x);
        U1(asinh, x * 1e-16);
        U1(atanh, x * 1e-16);

        double sub = s * mt_rand_double() * DBL_MIN;
        U1(asinh, sub);
        U1(atanh, sub);

        double near = s * mt_rand_double() * 1e-16;
        U1(asinh, near);
        U1(atanh, near);
    }
}

int main(void)
{
    printf("== asmlib math: invhyperbolic ==\n");
    test_specials();
    printf("   specials done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_uniform();
    printf("   uniform  done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random_bits();
    printf("   randbits done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_tiny();
    printf("   tiny     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("invhyperbolic");
}
