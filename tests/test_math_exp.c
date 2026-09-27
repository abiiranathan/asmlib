/*==============================================================================
 * test_math_exp.c - differential tests for exp.c
 *------------------------------------------------------------------------------
 * Compares asm_exp / asm_exp2 / asm_expm1 against the host libm over a table of
 * IEEE-754 special and boundary values plus a large body of pseudo-random
 * inputs: uniformly spread over [-750, 750], drawn from random bit patterns,
 * and tiny values near zero (which stress expm1's cancellation-free path).
 * Every result must be within 1 ulp of the reference.
 *============================================================================*/

#include "math_test.h"

#define U1(fn, x) mt_cmp(#fn, (x), ASM_MATH(fn)(x), fn(x), 1)

static const double SPECIALS[] = {
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5,
    0.69314718055994530942, -0.69314718055994530942,   /* ln2 */
    1.0 / 0.69314718055994530942,                      /* log2(e) */
    2.0, -2.0, 10.0, -10.0, 100.0, -100.0,
    DBL_MIN, -DBL_MIN, DBL_MAX, -DBL_MAX,
    0x1p-1022, -0x1p-1022, 0x1p-1074, -0x1p-1074,
    0x1p-1000, -0x1p-1000, 0x1p-540, -0x1p-540,
    709.0, 709.78271289338397, 709.7827128933841, 710.0, 710.1,
    -744.0, -744.44007192138122, -745.0, -745.1332191019411, -746.0,
    -1075.0, 1024.0, 1024.1, -1074.5, 1e300, -1e300,
    INFINITY, -INFINITY, NAN
};
#define NSPEC ((int)(sizeof SPECIALS / sizeof SPECIALS[0]))

static void test_specials(void)
{
    for (int i = 0; i < NSPEC; i++) {
        double x = SPECIALS[i];
        U1(exp, x);
        U1(exp2, x);
        U1(expm1, x);
    }
    /* Neighbours of the overflow / underflow thresholds, both directions. */
    const double edges[] = {
        709.78271289338397, 709.7827128933841, -744.44007192138122,
        -745.1332191019411, -745.2, -1074.0, -1075.0, 1023.9999999999999,
        1024.0, -0.5, 0.5
    };
    for (int i = 0; i < (int)(sizeof edges / sizeof edges[0]); i++) {
        for (int d = -2; d <= 2; d++) {
            double x = edges[i];
            for (int s = 0; s < (d < 0 ? -d : d); s++)
                x = nextafter(x, d > 0 ? INFINITY : -INFINITY);
            U1(exp, x);
            U1(exp2, x);
            U1(expm1, x);
        }
    }
}

static void test_random_bits(void)
{
    for (int k = 0; k < 40000; k++) {
        double x = mt_rand_bits();
        U1(exp, x);
        U1(exp2, x);
        U1(expm1, x);
    }
}

static void test_uniform(void)
{
    for (int k = 0; k < 30000; k++) {
        double x = (mt_rand_double() * 2.0 - 1.0) * 750.0;
        U1(exp, x);
        U1(exp2, x);
        U1(expm1, x);
    }
}

static void test_tiny(void)
{
    for (int k = 0; k < 20000; k++) {
        double sign = (mt_rand64() & 1) ? 1.0 : -1.0;
        double x = sign * mt_rand_double() * 1e-10;     /* ~[0, 1e-10] */
        U1(exp, x);
        U1(exp2, x);
        U1(expm1, x);

        x = sign * mt_rand_double() * 1e-8;             /* ~[0, 1e-8] */
        U1(exp, x);
        U1(exp2, x);
        U1(expm1, x);

        x = (mt_rand_double() - 0.5) * 1e-8;
        U1(exp, x);
        U1(exp2, x);
        U1(expm1, x);
    }
}

int main(void)
{
    printf("== asmlib math: exp ==\n");
    test_specials();
    printf("   specials    done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_random_bits();
    printf("   rand bits   done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_uniform();
    printf("   uniform     done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    test_tiny();
    printf("   tiny        done (%ld checks, %ld fails)\n", mt_checks, mt_fails);
    MT_RESULT("exp");
}
