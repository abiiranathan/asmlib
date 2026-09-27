/*==============================================================================
 * test_math_log.c - differential tests for log.c
 *------------------------------------------------------------------------------
 * Compares log/log2/log10/log1p against the host libm over a table of IEEE-754
 * special values and a large body of random inputs. A faithful result is
 * allowed at most 1 ulp. Inputs are chosen to exercise the reduction band, the
 * uniform range, the power-of-two/adjacent-to-1 cases and very tiny log1p
 * arguments.
 *============================================================================*/

#include "math_test.h"

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 2.0, 0.5, -0.5,
    INFINITY, -INFINITY, NAN,
    DBL_MAX, -DBL_MAX, DBL_MIN, -DBL_MIN,
    0x1p-1074, -0x1p-1074, 0x1p-1022, -0x1p-1022,
    0x1.0000000000001p0, 0x1.fffffffffffffp-1,
    1e300, -1e300, 1e-300, -1e-300
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

#define U1(fn, x) mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), 1)

static void test_specials(void)
{
    for (int i = 0; i < NSPEC; i++) {
        double x = SPECIALS[i];
        U1(log, x);
        U1(log2, x);
        U1(log10, x);
        U1(log1p, x);
    }
}

static void test_random(void)
{
    /* Full-range bit patterns: negatives are fed too (all logs must give NaN,
     * log1p must give NaN when x < -1). The positive magnitude is checked on
     * every routine. */
    for (int i = 0; i < 80000; i++) {
        double s = mt_rand_bits();
        double p = fabs(s);
        U1(log, p);
        U1(log2, p);
        U1(log10, p);
        U1(log1p, p);
        U1(log, s);
        U1(log2, s);
        U1(log10, s);
        U1(log1p, s);
    }

    /* Uniform positive values in (0, 1e6). */
    for (int i = 0; i < 40000; i++) {
        double x = mt_rand_double() * 1e6 + DBL_MIN;
        U1(log, x);
        U1(log2, x);
        U1(log10, x);
        U1(log1p, x);
    }

    /* Tiny arguments around zero: the critical log1p regime. */
    for (int i = 0; i < 40000; i++) {
        double t = (mt_rand_double() * 2.0 - 1.0) * 1e-12;
        double u = mt_rand_double() * 1e-300;
        double v = mt_rand_double() * DBL_MIN;
        U1(log1p, t);
        U1(log1p, u);
        U1(log1p, -u);
        U1(log1p, v);
    }
}

int main(void)
{
    printf("== asmlib math: log ==\n");
    test_specials();
    printf("   specials done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random();
    printf("   random   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("log");
}
