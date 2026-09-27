/*==============================================================================
 * math_test.h - shared helpers for the freestanding math differential tests
 *------------------------------------------------------------------------------
 * Each tests/test_math_*.c compares the asm_* implementation against the host
 * libm for the same inputs and reports the largest observed ULP difference.
 * Tests are compiled with -fno-builtin so reference calls are not folded and
 * the compiler cannot substitute its own libm.
 *
 * The RNG is a fixed-seed xorshift64* so failures reproduce exactly.
 *============================================================================*/

#ifndef ASMLIB_MATH_TEST_H
#define ASMLIB_MATH_TEST_H

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <float.h>

#include "asmlib_math.h"

#ifndef F64_EXP
#define F64_EXP 0x7ff0000000000000ULL   /* binary64 exponent field */
#endif
#define MT_UNUSED __attribute__((unused))

static MT_UNUSED long mt_checks;
static MT_UNUSED long mt_fails;
static MT_UNUSED uint64_t mt_rng_state = 0x123456789abcdef0ULL;
static MT_UNUSED uint64_t mt_maxulp;
static MT_UNUSED const char *mt_maxfn = "-";
static MT_UNUSED double mt_maxx;

static MT_UNUSED uint64_t mt_rand64(void)
{
    uint64_t x = mt_rng_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    mt_rng_state = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static MT_UNUSED double mt_rand_double(void)        /* uniform [0,1) */
{
    return (double)(mt_rand64() >> 11) * 0x1.0p-53;
}

/* A reproducible double assembled from random bits (finite, any exponent). */
static MT_UNUSED double mt_rand_bits(void)
{
    union { double f; uint64_t u; } v;
    v.u = mt_rand64();
    if ((v.u & F64_EXP) == F64_EXP)                 /* avoid Inf/NaN here */
        v.u ^= 1ULL << 52;
    return v.f;
}

/* Total ordering of doubles as unsigned integers (for ULP distance). */
static MT_UNUSED uint64_t mt_ord(double x)
{
    union { double f; uint64_t u; } v;
    v.f = x;
    if (v.u >> 63)
        return ~v.u + 1;                            /* negatives ascend */
    return v.u | 0x8000000000000000ULL;
}

/* ULP distance between two results; NaN==NaN counts as 0. */
static MT_UNUSED uint64_t mt_ulp(double a, double b)
{
    if (isnan(a) && isnan(b))
        return 0;
    if (isnan(a) || isnan(b))
        return UINT64_MAX / 2;
    if (a == b)
        return 0;                                   /* handles +/-0, inf */
    uint64_t oa = mt_ord(a), ob = mt_ord(b);
    return oa > ob ? oa - ob : ob - oa;
}

static MT_UNUSED void mt_check(int ok, const char *what, double x, double got,
                               double want, uint64_t ulp)
{
    mt_checks++;
    if (ulp != UINT64_MAX / 2 && ulp > mt_maxulp) {
        mt_maxulp = ulp;
        mt_maxfn = what;
        mt_maxx = x;
    }
    if (!ok) {
        mt_fails++;
        if (mt_fails <= 25)
            printf("  FAIL %-12s x=%-24.17g got=%-24.17g want=%-24.17g "
                   "ulp=%llu\n", what, x, got, want,
                   (unsigned long long)ulp);
    }
}

/* Compare got/want allowing up to maxulp. */
static MT_UNUSED void mt_cmp(const char *what, double x, double got, double want,
                             uint64_t maxulp)
{
    mt_check(mt_ulp(got, want) <= maxulp, what, x, got, want, mt_ulp(got, want));
}

/* Number of failures so far. */
#define MT_RESULT(name)                                                     \
    do {                                                                    \
        printf("  %-10s %8ld checks, %ld failures, max %llu ulp (%s at "   \
               "%.17g)\n", name, mt_checks, mt_fails,                       \
               (unsigned long long)mt_maxulp, mt_maxfn, mt_maxx);           \
        return mt_fails == 0 ? 0 : 1;                                       \
    } while (0)

#endif /* ASMLIB_MATH_TEST_H */
