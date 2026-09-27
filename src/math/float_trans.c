/*==============================================================================
 * float_trans.c - single-precision transcendental routines
 *------------------------------------------------------------------------------
 * Freestanding binary32 wrappers over this library's binary64 routines. Each
 * function promotes its arguments to double, calls the matching asm_* double
 * routine and rounds the result once back to float. The double routines
 * already implement the IEEE-754 special values (NaN, infinities, signed
 * zeros) and handle overflow/underflow, so the single float rounding produces
 * the correct float special values on its own.
 *
 * The result is faithful: at most 1 ulp from a correctly rounded float for
 * most inputs, and never more than 1 ulp from the double rounding. No errno,
 * no floating-point environment and no global state are used.
 *
 * Only "math_private.h" is included: it pulls in the public prototypes.
 *============================================================================*/

#include "math_private.h"

/* ---- exponential and logarithmic --------------------------------------- */

float ASM_MATH(expf)(float x)
{
    return (float)ASM_MATH(exp)((double)x);
}

float ASM_MATH(exp2f)(float x)
{
    return (float)ASM_MATH(exp2)((double)x);
}

float ASM_MATH(expm1f)(float x)
{
    return (float)ASM_MATH(expm1)((double)x);
}

float ASM_MATH(logf)(float x)
{
    return (float)ASM_MATH(log)((double)x);
}

float ASM_MATH(log2f)(float x)
{
    return (float)ASM_MATH(log2)((double)x);
}

float ASM_MATH(log10f)(float x)
{
    return (float)ASM_MATH(log10)((double)x);
}

float ASM_MATH(log1pf)(float x)
{
    return (float)ASM_MATH(log1p)((double)x);
}

float ASM_MATH(powf)(float x, float y)
{
    return (float)ASM_MATH(pow)((double)x, (double)y);
}

/* ---- trigonometric ----------------------------------------------------- */

float ASM_MATH(sinf)(float x)
{
    return (float)ASM_MATH(sin)((double)x);
}

float ASM_MATH(cosf)(float x)
{
    return (float)ASM_MATH(cos)((double)x);
}

float ASM_MATH(tanf)(float x)
{
    return (float)ASM_MATH(tan)((double)x);
}

void ASM_MATH(sincosf)(float x, float *sinp, float *cosp)
{
    double s, c;
    ASM_MATH(sincos)((double)x, &s, &c);
    *sinp = (float)s;
    *cosp = (float)c;
}

float ASM_MATH(asinf)(float x)
{
    return (float)ASM_MATH(asin)((double)x);
}

float ASM_MATH(acosf)(float x)
{
    return (float)ASM_MATH(acos)((double)x);
}

float ASM_MATH(atanf)(float x)
{
    return (float)ASM_MATH(atan)((double)x);
}

float ASM_MATH(atan2f)(float y, float x)
{
    return (float)ASM_MATH(atan2)((double)y, (double)x);
}

/* ---- hyperbolic and inverse hyperbolic --------------------------------- */

float ASM_MATH(sinhf)(float x)
{
    return (float)ASM_MATH(sinh)((double)x);
}

float ASM_MATH(coshf)(float x)
{
    return (float)ASM_MATH(cosh)((double)x);
}

float ASM_MATH(tanhf)(float x)
{
    return (float)ASM_MATH(tanh)((double)x);
}

float ASM_MATH(asinhf)(float x)
{
    return (float)ASM_MATH(asinh)((double)x);
}

float ASM_MATH(acoshf)(float x)
{
    return (float)ASM_MATH(acosh)((double)x);
}

float ASM_MATH(atanhf)(float x)
{
    return (float)ASM_MATH(atanh)((double)x);
}

/* ---- error and gamma functions ----------------------------------------- */

float ASM_MATH(erff)(float x)
{
    return (float)ASM_MATH(erf)((double)x);
}

float ASM_MATH(erfcf)(float x)
{
    return (float)ASM_MATH(erfc)((double)x);
}

float ASM_MATH(tgammaf)(float x)
{
    return (float)ASM_MATH(tgamma)((double)x);
}

float ASM_MATH(lgammaf)(float x)
{
    return (float)ASM_MATH(lgamma)((double)x);
}
