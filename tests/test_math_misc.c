/*==============================================================================
 * test_math_misc.c - differential tests for misc.c
 *------------------------------------------------------------------------------
 * Compares nextafter, remquo, the lrint/llrint/lround/llround family and nan
 * against the host libm. nextafter and remquo are exact, and the integer
 * conversions are integer-valued, so every finite result must match bit-for-bit
 * (0 ulp). nan() is only checked for being a quiet NaN.
 *============================================================================*/

#include "math_test.h"

#include <limits.h>

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 0.25, -0.25, 0.75, -0.75,
    1.5, -1.5, 2.0, -2.0, 2.5, -2.5, 3.0, -3.0, 3.5, -3.5,
    4.0, -4.0, 5.0, -5.0, 5.5, -5.5, 6.0, -6.0, 8.0, -8.0,
    DBL_MIN, -DBL_MIN, DBL_MAX, -DBL_MAX,
    1e300, -1e300, 1e-300, -1e-300, 1e16, -1e16, 1e-16, -1e-16,
    4503599627370496.0, -4503599627370496.0,             /* 2^52 */
    9007199254740992.0, -9007199254740992.0,             /* 2^53 */
    0x1p62, -0x1p62, 0x1p63, -0x1p63,                     /* 2^62, 2^63 */
    9223372036854774784.0, -9223372036854774784.0,       /* 2^63 - 1024 */
    2147483647.0, -2147483648.0, 2147483648.0,
    0x1p-1022, -0x1p-1022, 0x1p-1074, -0x1p-1074,
    0x1p-1000, -0x1p-1000, 0x1p1023, -0x1p1023,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

#define U2(fn, x, y, maxu) mt_cmp(#fn, (x), ASM_MATH(fn)(x, y), fn(x, y), (maxu))

/* mt_ulp treats +0 and -0 as equal; check the raw bits when a zero appears. */
static void check_zero_sign(const char *name, double x, double got, double want)
{
    if (want == 0.0) {
        union { double f; uint64_t u; } a, b;
        a.f = got;
        b.f = want;
        mt_check(a.u == b.u, name, x, got, want, 0);
    }
}

/* Integer comparisons report the exact long/long long values, not doubles. */
static void mt_long(const char *what, double x, long got, long want)
{
    mt_checks++;
    if (got != want) {
        mt_fails++;
        if (mt_fails <= 25)
            printf("  FAIL %-10s x=%-24.17g got=%ld want=%ld\n",
                   what, x, got, want);
    }
}

static void mt_ll(const char *what, double x, long long got, long long want)
{
    mt_checks++;
    if (got != want) {
        mt_fails++;
        if (mt_fails <= 25)
            printf("  FAIL %-10s x=%-24.17g got=%lld want=%lld\n",
                   what, x, got, want);
    }
}

#define U1L(fn, x)   mt_long(#fn, (x), ASM_MATH(fn)(x), (long)fn(x))
#define U1LL(fn, x)  mt_ll(#fn, (x), ASM_MATH(fn)(x), (long long)fn(x))

static void check_remquo(double x, double y)
{
    int qa = 0, qb = 0;
    double ra = ASM_MATH(remquo)(x, y, &qa);
    double rb = remquo(x, y, &qb);

    mt_cmp("remquo", x, ra, rb, 0);
    check_zero_sign("remquo", x, ra, rb);

    /* The C standard guarantees only the sign and the low 3 bits of the
     * quotient (n >= 3); glibc stores fewer bits than musl, so compare those. */
    if (!isnan(x) && !isnan(y) && !isinf(x) && !isinf(y) &&
        x != 0.0 && y != 0.0) {
        int lo_a = qa & 7, lo_b = qb & 7;
        int sgn_ok = (qa == 0 || qb == 0) || ((qa < 0) == (qb < 0));
        mt_checks++;
        if (lo_a != lo_b || !sgn_ok) {
            mt_fails++;
            if (mt_fails <= 25)
                printf("  FAIL remquo-q   x=%-24.17g y=%-24.17g got=%d want=%d\n",
                       x, y, qa, qb);
        }
    }
}

static void test_nextafter(void)
{
    for (int i = 0; i < NSPEC; i++) {
        for (int j = 0; j < NSPEC; j++) {
            double x = SPECIALS[i], y = SPECIALS[j];
            U2(nextafter, x, y, 0);
            check_zero_sign("nextafter", x, ASM_MATH(nextafter)(x, y),
                            nextafter(x, y));
        }
    }
    for (int k = 0; k < 50000; k++) {
        double x = mt_rand_bits(), y = mt_rand_bits();
        U2(nextafter, x, y, 0);
        U2(nextafter, y, x, 0);
        check_zero_sign("nextafter", x, ASM_MATH(nextafter)(x, y),
                        nextafter(x, y));
    }
    /* Walk across representable boundaries: zeros, subnormals, powers of two. */
    for (int k = 0; k < 20000; k++) {
        double x = mt_rand_bits();
        U2(nextafter, x, 0.0, 0);
        U2(nextafter, x, -0.0, 0);
        U2(nextafter, -x, 0.0, 0);
    }
}

static void test_remquo(void)
{
    for (int i = 0; i < NSPEC; i++)
        for (int j = 0; j < NSPEC; j++)
            check_remquo(SPECIALS[i], SPECIALS[j]);

    for (int k = 0; k < 50000; k++)
        check_remquo(mt_rand_bits(), mt_rand_bits());

    /* Exact ties and near-ties, to exercise q%2 and the rounding edge. */
    for (int e = -4; e <= 4; e++) {
        double y = ldexp(1.0, e);
        for (int k = 0; k < 64; k++) {
            double x = (2.0 * (double)k + 1.0) * (y * 0.5);
            check_remquo(x, y);
            check_remquo(-x, y);
            check_remquo(x, -y);
            check_remquo(-x, -y);
        }
    }
}

static void test_int_rounding_one(double x)
{
    U1L(lrint, x);
    U1LL(llrint, x);
    U1L(lround, x);
    U1LL(llround, x);
}

static void test_int_rounding(void)
{
    for (int i = 0; i < NSPEC; i++)
        test_int_rounding_one(SPECIALS[i]);

    for (int k = 0; k < 60000; k++)
        test_int_rounding_one(mt_rand_bits());

    /* Half-integers, where the two rounding rules disagree. */
    for (int k = -40; k <= 40; k++)
        test_int_rounding_one(0.5 * (double)k);

    /* Values straddling the half-integer boundaries at every exponent. */
    for (int e = 0; e <= 62; e++) {
        double base = ldexp(1.0, e);
        const double fracs[] = { 0.25, 0.5, 0.75, 0.9999999999999999,
                                 0.49999999999999994, 0.5000000000000001 };
        for (int f = 0; f < 6; f++) {
            double x = base * (1.0 + fracs[f]);
            test_int_rounding_one(x);
            test_int_rounding_one(-x);
        }
    }

    /* Explicit saturation boundaries for the 64-bit host. */
    test_int_rounding_one(9223372036854774784.0);    /* 2^63 - 1024 */
    test_int_rounding_one(-9223372036854774784.0);
    test_int_rounding_one(9223372036854775808.0);    /* 2^63 */
    test_int_rounding_one(-9223372036854775808.0);   /* -2^63 */
}

static void test_nan(void)
{
    union { double f; uint64_t u; } v;
    double a = ASM_MATH(nan)("payload");
    double b = ASM_MATH(nan)(NULL);
    double c = ASM_MATH(nan)("");
    mt_check(isnan(a) && isnan(b) && isnan(c), "nan-isnan", 0.0, a, c, 0);
    /* A quiet NaN has its sign bit clear and its quiet bit set. */
    v.f = a;
    mt_check(!signbit(a) && ((v.u >> 51) & 1) == 1, "nan-quiet", 0.0, a, c, 0);
}

int main(void)
{
    printf("== asmlib math: misc ==\n");
    test_nextafter();
    printf("   nextafter  done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_remquo();
    printf("   remquo     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_int_rounding();
    printf("   int round  done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_nan();
    printf("   nan        done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("misc");
}
