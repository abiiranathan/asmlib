/*==============================================================================
 * test_math_trig.c - differential tests for trig.c
 *------------------------------------------------------------------------------
 * Compares sin/cos/tan against the host libm over a table of IEEE-754 special
 * values (signed zeros, infinities, NaN, pi, pi/2, 3pi/2 and huge magnitudes)
 * plus well over 120,000 random inputs: uniform values in [-100,100], arbitrary
 * finite bit patterns with huge exponents, and values that sit within 1e-6 of
 * a multiple of pi/2 (the cancellation regime). sincos is required to agree
 * bit-for-bit with the separately exported sin and cos and within 1 ulp of the
 * host. A faithful result is allowed at most 1 ulp.
 *============================================================================*/

#include "math_test.h"

#define PI   3.14159265358979323846
#define PIO2 1.57079632679489661923

static const double SPECIALS[] = {
    0.0, -0.0,
    PI, -PI,
    PIO2, -PIO2,
    3.0 * PIO2, -3.0 * PIO2,
    2.0 * PI, -2.0 * PI,
    PI / 4.0, -PI / 4.0, PI / 6.0, -PI / 6.0,
    1e6, -1e6, 1e15, -1e15,
    1e300, -1e300, 1e-300, -1e-300,
    0x1p-1074, -0x1p-1074,
    0x1p-1022, -0x1p-1022,
    DBL_MIN, -DBL_MIN, DBL_MAX, -DBL_MAX,
    3.0, -3.0, 10.0, -10.0, 100.0, -100.0,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

#define U1(fn, x) mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), 1)

/* sin/cos/tan against the host, and sincos against both the host and the
 * separately exported kernels. */
static void check(double x)
{
    double ss, cc;

    U1(sin, x);
    U1(cos, x);
    U1(tan, x);

    ASM_MATH(sincos)(x, &ss, &cc);
    mt_cmp("sincos-sin", x, ss, sin(x), 1);
    mt_cmp("sincos-cos", x, cc, cos(x), 1);
    mt_cmp("sincos-vs-sin", x, ss, ASM_MATH(sin)(x), 0);
    mt_cmp("sincos-vs-cos", x, cc, ASM_MATH(cos)(x), 0);
}

static void test_specials(void)
{
    for (int i = 0; i < NSPEC; i++)
        check(SPECIALS[i]);

    /* The doubles immediately around pi/2 and 3pi/2, where the reduction
     * switches bands and the result is most cancellation-sensitive. */
    static const double pivots[] = { PIO2, 3.0 * PIO2, PI, 2.0 * PI };
    for (int i = 0; i < (int)(sizeof pivots / sizeof pivots[0]); i++) {
        double p = pivots[i];
        for (int d = -3; d <= 3; d++) {
            double q = p;
            for (int s = 0; s < (d < 0 ? -d : d); s++)
                q = nextafter(q, d > 0 ? INFINITY : -INFINITY);
            check(q);
            check(-q);
        }
    }
}

static void test_uniform(void)
{
    for (int i = 0; i < 45000; i++) {
        double x = (mt_rand_double() * 2.0 - 1.0) * 100.0;
        check(x);
    }
}

static void test_random_bits(void)
{
    /* Arbitrary finite bit patterns: huge exponents drive the Payne-Hanek
     * path, tiny subnormals drive the short-circuit path. */
    for (int i = 0; i < 45000; i++) {
        double x = mt_rand_bits();
        check(x);
    }
}

static void test_near_multiples(void)
{
    /* Values within 1e-6 of k*pi/2: the reduced argument is tiny, so the
     * result is entirely determined by the accuracy of the reduction. */
    for (int i = 0; i < 45000; i++) {
        int64_t k = (int64_t)(mt_rand64() % 2000001) - 1000000;
        double eps = (mt_rand_double() * 2.0 - 1.0) * 1e-6;
        if (mt_rand64() & 1)
            k = -k;
        check((double)k * PIO2 + eps);
    }
}

int main(void)
{
    printf("== asmlib math: trig ==\n");
    test_specials();
    printf("   specials done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_uniform();
    printf("   uniform  done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random_bits();
    printf("   bits     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_near_multiples();
    printf("   near     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("trig");
}
