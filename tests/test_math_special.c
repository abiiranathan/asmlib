/*==============================================================================
 * test_math_special.c - differential tests for erf, erfc, tgamma and lgamma
 *------------------------------------------------------------------------------
 * Compares the freestanding erf/erfc/tgamma/lgamma against the host libm over a
 * table of IEEE-754 special values plus random inputs.
 *
 * erf is allowed at most 1 ulp. erfc allows at most 2 ulp: the musl/FreeBSD
 * erfc uses a two-exp composition that is ~1.5 ulp from the correctly rounded
 * value, while contemporary glibc uses a newer Arm-derived erfc that is ~0.5
 * ulp, so the cross-library difference can reach 2 ulp.
 *
 * tgamma/lgamma are compared with a combined criterion: at most 3 ulp, or an
 * error of at most 1e-14 relative to max(1, |want|) (the two libms use
 * different but equally accurate algorithms, and lgamma crosses zero, where a
 * pure relative measure is meaningless). tgamma evaluates its Lanczos series
 * and exponential in double-double arithmetic, so it is within ~1 ulp for
 * positive arguments (a few ulp for negative ones via reflection); lgamma is
 * at most a few ulp including near its poles.
 *============================================================================*/

#include "math_test.h"

static const double ERF_SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 6.0, -6.0,
    1e-8, -1e-8, INFINITY, -INFINITY, NAN
};
#define NERF ((int)(sizeof ERF_SPECIALS / sizeof ERF_SPECIALS[0]))

static const double GAMMA_SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 6.0, -6.0,
    3.0, -3.0, 0.5, -0.5, 171.0, 172.0, -171.0,
    1e-8, -1e-8, 1e-300, -1e-300, INFINITY, -INFINITY, NAN
};
#define NGAM ((int)(sizeof GAMMA_SPECIALS / sizeof GAMMA_SPECIALS[0]))

#define U1(fn, x, maxu) mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), (maxu))

/* erf/erfc against a long-double oracle. The host libm erfc is *not* a safe
 * reference: glibc's is ~0.5 ulp while musl's (which this library ports) is
 * ~1.5 ulp, so a differential test can show a 3 ulp gap even though both are
 * faithful. Compute the reference with erfcl/erfl (long double, ~64-bit
 * mantissa - far more accurate than a double result needs) and require our
 * double result to be within maxu ulp of it. */
static MT_UNUSED void oracle_cmp(const char *what, double x, double got,
                                 long double ref, uint64_t maxu)
{
    double want = (double)ref;

    if (isnan((double)ref) || isnan(got)) {
        mt_check(isnan((double)ref) && isnan(got), what, x, got, want, 0);
        return;
    }
    mt_cmp(what, x, got, want, maxu);
}

#define O1(fn, x, ldexpr, maxu)                                              \
    oracle_cmp(#fn, (x), ASM_MATH(fn)(x), (ldexpr), (maxu))

/* Largest normalized relative error and largest meaningful ULP distance seen
 * by gamma_cmp. ULP distance is only tracked where |want| >= 1, since near
 * lgamma's zeros the ULP of the result is far below the algorithm's accuracy. */
static MT_UNUSED long double mt_maxrel;
static MT_UNUSED const char *mt_maxrelfn = "-";
static MT_UNUSED double mt_maxrelx;
static MT_UNUSED uint64_t mt_gmaxulp;
static MT_UNUSED const char *mt_gmaxfn = "-";
static MT_UNUSED double mt_gmaxx;
static MT_UNUSED uint64_t mt_tmaxulp, mt_lmaxulp;
static MT_UNUSED double mt_tmaxx, mt_lmaxx;

/* Compare two gamma-function magnitudes: exact for NaN/Inf/zero, otherwise
 * within 3 ulp or 1e-14 relative to max(1, |want|). Normalizing by the larger
 * of |want| and 1 keeps the criterion meaningful where lgamma crosses zero. */
static MT_UNUSED void gamma_cmp(const char *what, double x, double got,
                                double want)
{
    uint64_t u = mt_ulp(got, want);
    uint64_t track = u;
    long double rel = 0.0L;
    int ok;

    if (isnan(want)) {
        ok = isnan(got);
        u = 0;
        track = 0;
    } else if (isnan(got)) {
        ok = 0;
        u = 0;
        track = 0;
    } else if (isinf(want) || isinf(got)) {
        ok = (got == want);
        u = 0;
        track = 0;
    } else if (want == 0.0) {
        ok = (got == want);
        u = ok ? 0 : UINT64_MAX / 2;
        track = u;
    } else {
        long double mag = fabsl((long double)want);
        long double scale = mag < 1.0L ? 1.0L : mag;
        rel = fabsl(((long double)got - (long double)want)) / scale;
        if (rel > mt_maxrel) {
            mt_maxrel = rel;
            mt_maxrelfn = what;
            mt_maxrelx = x;
        }
        if (mag >= 1.0L && u > mt_gmaxulp) {
            mt_gmaxulp = u;
            mt_gmaxfn = what;
            mt_gmaxx = x;
        }
        if (mag >= 1.0L) {
            if (what[0] == 't') {
                if (u > mt_tmaxulp) { mt_tmaxulp = u; mt_tmaxx = x; }
            } else {
                if (u > mt_lmaxulp) { mt_lmaxulp = u; mt_lmaxx = x; }
            }
        }
        ok = (u <= 3) || (rel <= 1e-14L);
        if (mag < 1.0L && u > 3)
            track = 0;              /* ULP distance is meaningless near zero */
    }
    mt_check(ok, what, x, got, want, track);
}

/* The documented special-value conventions, asserted directly (not via libm). */
static void test_specials_explicit(void)
{
    double r;

    r = ASM_MATH(erf)(0.0);
    mt_check(r == 0.0 && !signbit(r), "erf(+0)", 0.0, r, 0.0, 0);
    r = ASM_MATH(erf)(-0.0);
    mt_check(r == 0.0 && signbit(r), "erf(-0)", -0.0, r, -0.0, 0);
    mt_check(ASM_MATH(erf)(INFINITY) == 1.0, "erf(+inf)", INFINITY,
             ASM_MATH(erf)(INFINITY), 1.0, 0);
    mt_check(ASM_MATH(erf)(-INFINITY) == -1.0, "erf(-inf)", -INFINITY,
             ASM_MATH(erf)(-INFINITY), -1.0, 0);

    r = ASM_MATH(erfc)(0.0);
    mt_check(r == 1.0, "erfc(+0)", 0.0, r, 1.0, 0);
    mt_check(ASM_MATH(erfc)(INFINITY) == 0.0, "erfc(+inf)", INFINITY,
             ASM_MATH(erfc)(INFINITY), 0.0, 0);
    mt_check(ASM_MATH(erfc)(-INFINITY) == 2.0, "erfc(-inf)", -INFINITY,
             ASM_MATH(erfc)(-INFINITY), 2.0, 0);

    mt_check(ASM_MATH(tgamma)(1.0) == 1.0, "tgamma(1)", 1.0,
             ASM_MATH(tgamma)(1.0), 1.0, 0);
    mt_check(ASM_MATH(tgamma)(2.0) == 1.0, "tgamma(2)", 2.0,
             ASM_MATH(tgamma)(2.0), 1.0, 0);
    mt_check(ASM_MATH(tgamma)(4.0) == 6.0, "tgamma(4)", 4.0,
             ASM_MATH(tgamma)(4.0), 6.0, 0);
    mt_check(isinf(ASM_MATH(tgamma)(0.0)) && ASM_MATH(tgamma)(0.0) > 0,
             "tgamma(+0)", 0.0, ASM_MATH(tgamma)(0.0), INFINITY, 0);
    mt_check(isinf(ASM_MATH(tgamma)(-0.0)) && ASM_MATH(tgamma)(-0.0) < 0,
             "tgamma(-0)", -0.0, ASM_MATH(tgamma)(-0.0), -INFINITY, 0);
    mt_check(isnan(ASM_MATH(tgamma)(-1.0)), "tgamma(-1)", -1.0,
             ASM_MATH(tgamma)(-1.0), NAN, 0);
    mt_check(isnan(ASM_MATH(tgamma)(-2.0)), "tgamma(-2)", -2.0,
             ASM_MATH(tgamma)(-2.0), NAN, 0);

    mt_check(ASM_MATH(lgamma)(1.0) == 0.0, "lgamma(1)", 1.0,
             ASM_MATH(lgamma)(1.0), 0.0, 0);
    mt_check(ASM_MATH(lgamma)(2.0) == 0.0, "lgamma(2)", 2.0,
             ASM_MATH(lgamma)(2.0), 0.0, 0);
    mt_check(isinf(ASM_MATH(lgamma)(0.0)) && ASM_MATH(lgamma)(0.0) > 0,
             "lgamma(0)", 0.0, ASM_MATH(lgamma)(0.0), INFINITY, 0);
    mt_check(isinf(ASM_MATH(lgamma)(-1.0)) && ASM_MATH(lgamma)(-1.0) > 0,
             "lgamma(-1)", -1.0, ASM_MATH(lgamma)(-1.0), INFINITY, 0);
    mt_check(isinf(ASM_MATH(lgamma)(-2.0)) && ASM_MATH(lgamma)(-2.0) > 0,
             "lgamma(-2)", -2.0, ASM_MATH(lgamma)(-2.0), INFINITY, 0);
    mt_check(isinf(ASM_MATH(lgamma)(INFINITY)), "lgamma(+inf)", INFINITY,
             ASM_MATH(lgamma)(INFINITY), INFINITY, 0);
    mt_check(isinf(ASM_MATH(lgamma)(-INFINITY)), "lgamma(-inf)", -INFINITY,
             ASM_MATH(lgamma)(-INFINITY), INFINITY, 0);
}

static void test_erf(void)
{
    int i, k;

    for (i = 0; i < NERF; i++) {
        O1(erf, ERF_SPECIALS[i], erfl((long double)ERF_SPECIALS[i]), 1);
        O1(erfc, ERF_SPECIALS[i], erfcl((long double)ERF_SPECIALS[i]), 2);
    }

    /* uniform [-6,6], the whole interesting range of erf */
    for (k = 0; k < 120000; k++) {
        double x = 12.0 * mt_rand_double() - 6.0;
        O1(erf, x, erfl((long double)(x)), 1);
        O1(erfc, x, erfcl((long double)(x)), 2);
    }
    /* tiny arguments down to about 2^-100 */
    for (k = 0; k < 30000; k++) {
        int e = 20 + (int)(mt_rand64() % 80);
        double x = (2.0 * mt_rand_double() - 1.0) * ldexp(1.0, -e);
        O1(erf, x, erfl((long double)(x)), 1);
        O1(erfc, x, erfcl((long double)(x)), 2);
    }
    /* large arguments, including the saturated tails */
    for (k = 0; k < 30000; k++) {
        int e = 4 + (int)(mt_rand64() % 996);
        double x = (2.0 * mt_rand_double() - 1.0) * ldexp(1.0, e);
        O1(erf, x, erfl((long double)(x)), 1);
        O1(erfc, x, erfcl((long double)(x)), 2);
    }
}

static void test_gamma(void)
{
    int i, k;

    for (i = 0; i < NGAM; i++) {
        double x = GAMMA_SPECIALS[i];
        gamma_cmp("tgamma", x, ASM_MATH(tgamma)(x), tgamma(x));
        gamma_cmp("lgamma", x, ASM_MATH(lgamma)(x), lgamma(x));
    }

    /* uniform [-6,6] */
    for (k = 0; k < 120000; k++) {
        double x = 12.0 * mt_rand_double() - 6.0;
        gamma_cmp("tgamma", x, ASM_MATH(tgamma)(x), tgamma(x));
        gamma_cmp("lgamma", x, ASM_MATH(lgamma)(x), lgamma(x));
    }
    /* just beside the poles at 0 and the negative integers */
    for (k = 0; k < 40000; k++) {
        int n = 1 + (int)(mt_rand64() % 6);
        double d = (mt_rand_double() - 0.5) * 1e-2;
        double x = -n + d;
        gamma_cmp("tgamma", x, ASM_MATH(tgamma)(x), tgamma(x));
        gamma_cmp("lgamma", x, ASM_MATH(lgamma)(x), lgamma(x));
    }
    /* tiny positive and negative arguments */
    for (k = 0; k < 20000; k++) {
        int e = 10 + (int)(mt_rand64() % 90);
        double x = (mt_rand_double() < 0.5 ? -1.0 : 1.0) * 1e-8 * ldexp(1.0, -e);
        gamma_cmp("tgamma", x, ASM_MATH(tgamma)(x), tgamma(x));
        gamma_cmp("lgamma", x, ASM_MATH(lgamma)(x), lgamma(x));
    }
    /* large positive arguments (through the overflow threshold) */
    for (k = 0; k < 40000; k++) {
        double x = 8.0 + mt_rand_double() * 180.0;
        gamma_cmp("tgamma", x, ASM_MATH(tgamma)(x), tgamma(x));
        gamma_cmp("lgamma", x, ASM_MATH(lgamma)(x), lgamma(x));
    }
    /* large negative arguments (through the underflow threshold) */
    for (k = 0; k < 40000; k++) {
        double x = -8.0 - mt_rand_double() * 180.0;
        gamma_cmp("tgamma", x, ASM_MATH(tgamma)(x), tgamma(x));
        gamma_cmp("lgamma", x, ASM_MATH(lgamma)(x), lgamma(x));
    }
}

int main(void)
{
    printf("== asmlib math: special (erf/erfc/tgamma/lgamma) ==\n");
    test_specials_explicit();
    printf("   explicit    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_erf();
    printf("   erf/erfc    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_gamma();
    printf("   gamma       done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    printf("   max normalized relative error %Lg (%s at %.17g)\n",
           mt_maxrel, mt_maxrelfn, mt_maxrelx);
    printf("   gamma max ulp (|result| >= 1)    %llu (%s at %.17g)\n",
           (unsigned long long)mt_gmaxulp, mt_gmaxfn, mt_gmaxx);
    printf("   tgamma max ulp %llu (at %.17g) | lgamma max ulp %llu (at %.17g)\n",
           (unsigned long long)mt_tmaxulp, mt_tmaxx,
           (unsigned long long)mt_lmaxulp, mt_lmaxx);
    MT_RESULT("special");
}
