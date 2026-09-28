/**
 * @file asmlib_math.h
 * @brief Freestanding double-precision math library.
 * SPDX-License-Identifier: MIT
 *
 * A libc-free, WebAssembly-friendly reimplementation of the C <math.h>
 * double-precision surface. It has no external dependencies: no libc, no
 * libm, no errno, no floating-point environment and no global state. It is
 * suitable for freestanding targets (compile with -ffreestanding and link
 * nothing) and is built for WebAssembly (wasm32) by the top-level Makefile.
 *
 * Naming
 * ------
 * By default every function is prefixed `asm_` (asm_sin, asm_log, ...) so it
 * can coexist with a hosted libm during testing. Define
 * ASMLIB_MATH_STD_NAMES before including this header (and when compiling the
 * library) to expose the standard names (sin, log, ...) instead - this is
 * what the wasm build does so the module can act as a drop-in libm.
 *
 * Conventions
 * -----------
 *   - All functions operate on IEEE-754 binary64 (double).
 *   - Accuracy target is faithful (< 1 ulp) except where exactness is
 *     required (fabs, copysign, fmod, scalbn, ...).
 *   - Special values follow IEEE-754: NaN propagates, infinities and signed
 *     zero behave as <math.h> requires. No function sets errno.
 *   - No function uses the C floating-point environment, so rint/nearbyint
 *     always round to nearest-even (the only wasm mode).
 *============================================================================*/

#ifndef ASMLIB_MATH_H
#define ASMLIB_MATH_H

#ifdef __cplusplus
extern "C" {
#endif

/* Map the public spelling of each routine. The library sources use the same
 * macro so a single build can produce either asm_* or standard symbols. */
#ifdef ASMLIB_MATH_STD_NAMES
#define ASM_MATH(name) name
#else
#define ASM_MATH(name) asm_##name
#endif

/* ---- rounding, sign and comparison ------------------------------------- */
double ASM_MATH(fabs)(double x);                    /* |x|                        */
double ASM_MATH(copysign)(double x, double y);      /* magnitude x, sign of y     */
double ASM_MATH(fmin)(double x, double y);          /* smaller, NaN-aware         */
double ASM_MATH(fmax)(double x, double y);          /* larger, NaN-aware          */
double ASM_MATH(fdim)(double x, double y);          /* max(x-y, +0), NaN-aware    */
double ASM_MATH(floor)(double x);                   /* round down                 */
double ASM_MATH(ceil)(double x);                    /* round up                   */
double ASM_MATH(trunc)(double x);                   /* round toward zero          */
double ASM_MATH(round)(double x);                   /* half away from zero        */
double ASM_MATH(rint)(double x);                    /* nearest, ties to even      */
double ASM_MATH(nearbyint)(double x);               /* nearest, ties to even      */

/* ---- binary decomposition and scaling ---------------------------------- */
double ASM_MATH(ldexp)(double x, int n);            /* x * 2^n                    */
double ASM_MATH(scalbn)(double x, int n);           /* x * 2^n                    */
double ASM_MATH(frexp)(double x, int *exp);         /* x = m * 2^e, m in [0.5,1)  */
double ASM_MATH(modf)(double x, double *iptr);      /* split integer/fraction     */
int    ASM_MATH(ilogb)(double x);                   /* floor(log2(|x|))           */
double ASM_MATH(logb)(double x);                    /* floor(log2(|x|)), as double*/

/* ---- arithmetic -------------------------------------------------------- */
double ASM_MATH(fmod)(double x, double y);          /* truncated remainder        */
double ASM_MATH(remainder)(double x, double y);     /* IEEE remainder (round-even)*/
double ASM_MATH(remquo)(double x, double y, int *quo); /* remainder + quotient    */
double ASM_MATH(sqrt)(double x);                    /* square root                */
double ASM_MATH(cbrt)(double x);                    /* cube root                  */
double ASM_MATH(hypot)(double x, double y);         /* sqrt(x*x + y*y), no overflow */

/* ---- neighbouring values and integer conversion ------------------------ */
double ASM_MATH(nextafter)(double x, double y);     /* next double toward y       */
long   ASM_MATH(lrint)(double x);                   /* round nearest-even -> long */
long long ASM_MATH(llrint)(double x);               /* round nearest-even -> ll   */
long   ASM_MATH(lround)(double x);                  /* round away from zero->long */
long long ASM_MATH(llround)(double x);              /* round away -> long long    */
double ASM_MATH(nan)(const char *tag);              /* quiet NaN (tag ignored)    */

/* ---- fused multiply-add ------------------------------------------------ */
double ASM_MATH(fma)(double x, double y, double z); /* correctly rounded x*y + z   */

/* ---- error and gamma functions ---------------------------------------- */
double ASM_MATH(erf)(double x);                     /* error function             */
double ASM_MATH(erfc)(double x);                    /* complementary error func   */
double ASM_MATH(tgamma)(double x);                  /* true gamma                 */
double ASM_MATH(lgamma)(double x);                  /* log |gamma(x)|             */

/* ---- exponential and logarithmic -------------------------------------- */
double ASM_MATH(exp)(double x);
double ASM_MATH(exp2)(double x);
double ASM_MATH(expm1)(double x);
double ASM_MATH(log)(double x);
double ASM_MATH(log2)(double x);
double ASM_MATH(log10)(double x);
double ASM_MATH(log1p)(double x);
double ASM_MATH(pow)(double x, double y);

/* ---- trigonometric ----------------------------------------------------- */
double ASM_MATH(sin)(double x);
double ASM_MATH(cos)(double x);
double ASM_MATH(tan)(double x);
void   ASM_MATH(sincos)(double x, double *sinp, double *cosp);

/* ---- inverse trigonometric -------------------------------------------- */
double ASM_MATH(asin)(double x);
double ASM_MATH(acos)(double x);
double ASM_MATH(atan)(double x);
double ASM_MATH(atan2)(double y, double x);

/* ---- hyperbolic -------------------------------------------------------- */
double ASM_MATH(sinh)(double x);
double ASM_MATH(cosh)(double x);
double ASM_MATH(tanh)(double x);

/* ---- inverse hyperbolic ------------------------------------------------ */
double ASM_MATH(asinh)(double x);
double ASM_MATH(acosh)(double x);
double ASM_MATH(atanh)(double x);

/*==============================================================================
 * Single precision (float) variants
 *------------------------------------------------------------------------------
 * The same routine set for IEEE-754 binary32. Faithful (<= 1 ulp); most are
 * evaluated in double and rounded once to float.
 *============================================================================*/

/* sign / select */
float ASM_MATH(fabsf)(float x);
float ASM_MATH(copysignf)(float x, float y);
float ASM_MATH(fminf)(float x, float y);
float ASM_MATH(fmaxf)(float x, float y);
float ASM_MATH(fdimf)(float x, float y);
float ASM_MATH(floorf)(float x);
float ASM_MATH(ceilf)(float x);
float ASM_MATH(truncf)(float x);
float ASM_MATH(roundf)(float x);
float ASM_MATH(rintf)(float x);
float ASM_MATH(nearbyintf)(float x);

/* decomposition / scaling */
float ASM_MATH(ldexpf)(float x, int n);
float ASM_MATH(scalbnf)(float x, int n);
float ASM_MATH(frexpf)(float x, int *exp);
float ASM_MATH(modff)(float x, float *iptr);
int   ASM_MATH(ilogbf)(float x);
float ASM_MATH(logbf)(float x);

/* arithmetic */
float ASM_MATH(fmodf)(float x, float y);
float ASM_MATH(remainderf)(float x, float y);
float ASM_MATH(remquof)(float x, float y, int *quo);
float ASM_MATH(sqrtf)(float x);
float ASM_MATH(cbrtf)(float x);
float ASM_MATH(hypotf)(float x, float y);
float ASM_MATH(nextafterf)(float x, float y);

/* fma / integer rounding / nan */
float ASM_MATH(fmaf)(float x, float y, float z);
long      ASM_MATH(lrintf)(float x);
long long ASM_MATH(llrintf)(float x);
long      ASM_MATH(lroundf)(float x);
long long ASM_MATH(llroundf)(float x);
float     ASM_MATH(nanf)(const char *tag);

/* exponential / log / pow */
float ASM_MATH(expf)(float x);
float ASM_MATH(exp2f)(float x);
float ASM_MATH(expm1f)(float x);
float ASM_MATH(logf)(float x);
float ASM_MATH(log2f)(float x);
float ASM_MATH(log10f)(float x);
float ASM_MATH(log1pf)(float x);
float ASM_MATH(powf)(float x, float y);

/* trig / inverse */
float ASM_MATH(sinf)(float x);
float ASM_MATH(cosf)(float x);
float ASM_MATH(tanf)(float x);
void  ASM_MATH(sincosf)(float x, float *sinp, float *cosp);
float ASM_MATH(asinf)(float x);
float ASM_MATH(acosf)(float x);
float ASM_MATH(atanf)(float x);
float ASM_MATH(atan2f)(float y, float x);

/* hyperbolic / inverse */
float ASM_MATH(sinhf)(float x);
float ASM_MATH(coshf)(float x);
float ASM_MATH(tanhf)(float x);
float ASM_MATH(asinhf)(float x);
float ASM_MATH(acoshf)(float x);
float ASM_MATH(atanhf)(float x);

/* erf / gamma */
float ASM_MATH(erff)(float x);
float ASM_MATH(erfcf)(float x);
float ASM_MATH(tgammaf)(float x);
float ASM_MATH(lgammaf)(float x);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ASMLIB_MATH_H */
