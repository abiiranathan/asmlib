/*==============================================================================
 * upstream.h - compatibility shims for the musl-derived fast math kernels
 *------------------------------------------------------------------------------
 * The fast paths of this library (exp/log/pow and the hyperbolics) are adapted
 * from musl libc, which is MIT licensed (see NOTICE in this directory). musl's
 * sources are written against <math.h> and its internal "libm.h"; those are
 * replaced here by this header, which maps the few names they use onto this
 * library's freestanding internals (math_private.h) and onto the standard
 * ASM_MATH() symbol spelling.
 *
 * Include this header INSTEAD of <math.h>/"libm.h" in a ported file. It also
 * provides the function-like name macros (exp, log, ...) that rename both the
 * definitions and the internal calls of the ported sources to asm_* symbols,
 * so the ported bodies can stay close to upstream.
 *============================================================================*/

#ifndef ASMLIB_MATH_UPSTREAM_H
#define ASMLIB_MATH_UPSTREAM_H

#include <stdint.h>
#include <float.h>

#include "math_private.h"       /* ASM_MATH, f64_* helpers, F64_* constants */

typedef double double_t;
typedef float  float_t;

#define WANT_ROUNDING 1
#define WANT_SNAN 0
#define issignaling_inline(x) 0

#ifndef TOINT_INTRINSICS
#define TOINT_INTRINSICS 0
#endif

/* Standard IEEE constants without pulling in a hosted <math.h>. */
#define INFINITY  F64_INF
#define HUGE_VAL  F64_INF
#define NAN       F64_QNAN

#define predict_true(x)  __builtin_expect(!!(x), 1)
#define predict_false(x) __builtin_expect((x), 0)

static inline double eval_as_double(double x)
{
    double y = x;
    return y;
}

static inline double fp_barrier(double x)
{
    volatile double y = x;
    return y;
}

static inline void fp_force_eval(double x)
{
    volatile double y;
    y = x;
    (void)y;
}

#define FORCE_EVAL(x) do {                                                   \
    if (sizeof(x) == sizeof(float)) {                                        \
        volatile float _asmlib_fe = (float)(x); (void)_asmlib_fe;            \
    } else {                                                                 \
        fp_force_eval(x);                                                    \
    }                                                                        \
} while (0)

#define asuint64(f) ((union{ double _f; uint64_t _i; }){ f })._i
#define asdouble(i) ((union{ uint64_t _i; double _f; }){ i })._f

#define INSERT_WORDS(d, hi, lo)                                              \
    do { (d) = asdouble(((uint64_t)(hi) << 32) | (uint32_t)(lo)); } while (0)

/* ---- musl's special-value helpers, reduced to plain returns (no errno) --- */
static inline double __math_invalid(double x)
{
    return (x - x) / (x - x);
}
static inline double __math_xflow(uint32_t sign, double y)
{
    return eval_as_double(fp_barrier(sign ? -y : y) * y);
}
static inline double __math_oflow(uint32_t sign)
{
    return __math_xflow(sign, 0x1p769);
}
static inline double __math_uflow(uint32_t sign)
{
    return __math_xflow(sign, 0x1p-767);
}
static inline double __math_divzero(uint32_t sign)
{
    return fp_barrier(sign ? -1.0 : 1.0) / 0.0;
}

/* exp(x)/2 for large x, shared by sinh/cosh/tanh (defined in __expo2.c). */
double __expo2(double x, double sign);

/* Predicates and the handful of libm calls the kernels make. */
#define isnan(x)   f64_isnan(x)
#define isinf(x)   f64_isinf(x)
#define isfinite(x) (!f64_isnan(x) && !f64_isinf(x))
#define signbit(x) f64_signbit(x)
#define fabs(x)       ASM_MATH(fabs)(x)
#define sqrt(x)       ASM_MATH(sqrt)(x)
#define copysign(x, y) ASM_MATH(copysign)(x, y)
#define scalbn(x, n)  ASM_MATH(scalbn)(x, n)

/* Public names: rewrite the ported definitions and calls to the asm_ spelling. */
#define exp(x)       ASM_MATH(exp)(x)
#define exp2(x)      ASM_MATH(exp2)(x)
#define expm1(x)     ASM_MATH(expm1)(x)
#define log(x)       ASM_MATH(log)(x)
#define log2(x)      ASM_MATH(log2)(x)
#define log10(x)     ASM_MATH(log10)(x)
#define log1p(x)     ASM_MATH(log1p)(x)
#define pow(x, y)    ASM_MATH(pow)(x, y)
#define cbrt(x)      ASM_MATH(cbrt)(x)
#define hypot(x, y)  ASM_MATH(hypot)(x, y)
#define sinh(x)      ASM_MATH(sinh)(x)
#define cosh(x)      ASM_MATH(cosh)(x)
#define tanh(x)      ASM_MATH(tanh)(x)
#define asinh(x)     ASM_MATH(asinh)(x)
#define acosh(x)     ASM_MATH(acosh)(x)
#define atanh(x)     ASM_MATH(atanh)(x)

#endif /* ASMLIB_MATH_UPSTREAM_H */
