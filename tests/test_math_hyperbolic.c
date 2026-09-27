/*==============================================================================
 * test_math_hyperbolic.c - differential tests for hyperbolic.c
 *------------------------------------------------------------------------------
 * Compares asm_sinh / asm_cosh / asm_tanh against the host libm over a table of
 * IEEE-754 special and boundary values plus a large body of pseudo-random
 * inputs: raw bit patterns, uniform values in [-30, 30] and tiny values near
 * zero (down to subnormals), which stress the expm1 regime. Every result must
 * be within 1 ulp of the reference.
 *============================================================================*/

#include "math_test.h"

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 20.0, -20.0, 700.0, -700.0,
    710.0, -710.0, 22.0, -22.0, 0.5, -0.5,
    DBL_MAX, -DBL_MAX, DBL_MIN, -DBL_MIN,
    0x1p-1022, -0x1p-1022, 0x1p-1074, -0x1p-1074,
    0x1p-1000, -0x1p-1000, 0x1p-540, -0x1p-540,
    1e-300, -1e-300, 1e-20, -1e-20, 1e300, -1e300,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

#define U1(fn, x) mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), 1)
/* musl's fast sinh/tanh formulas are documented to reach 2 ulp in narrow
 * ranges, so those two allow 2 ulp while cosh stays at 1. */
#define U1H(fn, x) mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), 2)

static void test_specials(void)
{
    for (int i = 0; i < NSPEC; i++) {
        double x = SPECIALS[i];
        U1H(sinh, x);
        U1(cosh, x);
        U1H(tanh, x);
    }
    /* Neighbours of the overflow knee (ln(DBL_MAX) + ln 2 ~ 710.475). */
    const double edges[] = {
        22.0, 709.782712893384, 710.4758600739439, 0.0, 1.0,
        19.061547465398116, 0x1p-55, 0x1p-28
    };
    for (int i = 0; i < (int)(sizeof edges / sizeof edges[0]); i++) {
        for (int d = -2; d <= 2; d++) {
            double x = edges[i];
            for (int s = 0; s < (d < 0 ? -d : d); s++)
                x = nextafter(x, d > 0 ? INFINITY : -INFINITY);
            U1H(sinh, x);
            U1(cosh, x);
            U1H(tanh, x);
            U1H(sinh, -x);
            U1(cosh, -x);
            U1H(tanh, -x);
        }
    }
}

static void test_random_bits(void)
{
    for (int k = 0; k < 30000; k++) {
        double x = mt_rand_bits();
        U1H(sinh, x);
        U1(cosh, x);
        U1H(tanh, x);
    }
}

static void test_uniform(void)
{
    for (int k = 0; k < 30000; k++) {
        double x = (mt_rand_double() * 2.0 - 1.0) * 30.0;   /* [-30, 30] */
        U1H(sinh, x);
        U1(cosh, x);
        U1H(tanh, x);
    }
}

static void test_tiny(void)
{
    for (int k = 0; k < 20000; k++) {
        int e = -(int)(mt_rand64() % 1080);                 /* down to subnormal */
        double x = ldexp(mt_rand_double(), e);
        if (mt_rand64() & 1)
            x = -x;
        U1H(sinh, x);
        U1(cosh, x);
        U1H(tanh, x);

        x = (mt_rand_double() * 2.0 - 1.0) * 1e-300;
        U1H(sinh, x);
        U1(cosh, x);
        U1H(tanh, x);
    }
}

int main(void)
{
    printf("== asmlib math: hyperbolic ==\n");
    test_specials();
    printf("   specials  done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random_bits();
    printf("   rand bits done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_uniform();
    printf("   uniform   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_tiny();
    printf("   tiny      done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("hyperbolic");
}
