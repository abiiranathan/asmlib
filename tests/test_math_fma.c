/*==============================================================================
 * test_math_fma.c - differential tests for fma.c
 *------------------------------------------------------------------------------
 * fma is correctly rounded, so every result must match the host libm bit-for-bit.
 * We compare over all triples of an IEEE-754 special-value table (including
 * cancellation and 0*Inf cases), over 150,000 random triples from mt_rand_bits,
 * and over 100,000 small-integer triples chosen to force cancellation.
 * mt_ulp treats +0 and -0 as equal and NaN==NaN as 0, so the sign of zero
 * results is additionally checked bit-for-bit.
 *============================================================================*/

#include "math_test.h"

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0, 0.5, -0.5,
    0.25, -0.25, 0.75, -0.75, 1.5, -1.5,
    1e16, -1e16, 1e-16, -1e-16, 1e300, -1e300, 1e-300, -1e-300,
    9007199254740992.0, -9007199254740992.0,           /* 2^53            */
    9007199254740993.0, -9007199254740993.0,           /* 2^53 + 1        */
    0x1.fffffffffffffp+52, -0x1.fffffffffffffp+52,
    0x1p-1022, -0x1p-1022, 0x1p-1074, -0x1p-1074, 0x1p-1000, -0x1p-1000,
    DBL_MIN, -DBL_MIN, DBL_MAX, -DBL_MAX,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

#define U3(fn, x, y, z) \
    mt_cmp(#fn, (x), ASM_MATH(fn)(x, y, z), fn(x, y, z), 0)

/* mt_ulp collapses +0 and -0; verify the raw bits when a zero is expected. */
static void check_zero_sign(const char *name, double x, double y, double z)
{
    double got = ASM_MATH(fma)(x, y, z);
    double want = fma(x, y, z);
    if (want == 0.0) {
        union { double f; uint64_t u; } a, b;
        a.f = got;
        b.f = want;
        mt_check(a.u == b.u, name, x, got, want, 0);
    }
}

static void test_specials(void)
{
    for (int i = 0; i < NSPEC; i++)
        for (int j = 0; j < NSPEC; j++)
            for (int k = 0; k < NSPEC; k++) {
                double x = SPECIALS[i], y = SPECIALS[j], z = SPECIALS[k];
                U3(fma, x, y, z);
                check_zero_sign("fma-zero", x, y, z);
            }
}

/* A handful of textbook cases, including 0*Inf -> NaN and sharp cancellation. */
static void test_known_cases(void)
{
    static const double cases[][3] = {
        { 0.0, INFINITY, 1.0 }, { INFINITY, 0.0, 1.0 },
        { 0.0, -INFINITY, 1.0 }, { -INFINITY, 0.0, 1.0 },
        { 1.0, 1.0, 1.0 }, { 1e16, 1.0, -1e16 },
        { 1e16, 1.0, -(1e16 - 2.0) }, { 1.0, 1e-300, 1e-300 },
        { DBL_MAX, 2.0, -INFINITY }, { DBL_MAX, 2.0, DBL_MAX },
        { 0x1p-1074, 0.5, 0.0 }, { 0x1p-1074, 2.0, 0x1p-1074 },
        { 123456789.0, 987654321.0, -121932631112635269.0 },
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        U3(fma, cases[i][0], cases[i][1], cases[i][2]);
        check_zero_sign("fma-zero", cases[i][0], cases[i][1], cases[i][2]);
    }
}

static void test_random_bits(void)
{
    for (int k = 0; k < 150000; k++) {
        double x = mt_rand_bits();
        double y = mt_rand_bits();
        double z = mt_rand_bits();
        U3(fma, x, y, z);
        check_zero_sign("fma-zero", x, y, z);
    }
}

/* Small integers: x*y is exact or nearly exact, and z is placed at -(x*y) to
 * force the add path to cancel catastrophically. */
static void test_cancellation(void)
{
    for (int k = 0; k < 100000; k++) {
        double x = (double)((int)(mt_rand64() % 1001) - 500);
        double y = (double)((int)(mt_rand64() % 1001) - 500);
        double p = x * y;
        double z;

        switch (mt_rand64() % 4) {
        case 0: z = -p; break;                          /* exact zero      */
        case 1: z = -p + (double)((int)(mt_rand64() % 5) - 2); break;
        case 2: z = -p * (1.0 + 0x1p-52); break;        /* next to zero    */
        default: z = -p - (double)((int)(mt_rand64() % 5) - 2); break;
        }
        U3(fma, x, y, z);
        check_zero_sign("fma-zero", x, y, z);
    }
    /* Large significands: the product itself rounds, so the fused result is a
     * tiny non-zero residue of the rounded product instead of zero. */
    for (int k = 0; k < 10000; k++) {
        double x = (double)(0x1fffffffffffffULL - (mt_rand64() % 4096));
        double y = (double)(1 + mt_rand64() % 5);
        double z = -x * y;
        U3(fma, x, y, z);
        U3(fma, -x, y, -z);
    }
}

int main(void)
{
    printf("== asmlib math: fma ==\n");
    test_known_cases();
    printf("   known     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_specials();
    printf("   specials  done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random_bits();
    printf("   random    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_cancellation();
    printf("   cancel    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("fma");
}
