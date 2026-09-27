/*==============================================================================
 * math_private.h - internal helpers shared by the freestanding math routines
 *------------------------------------------------------------------------------
 * This header is included by every translation unit under src/math. It pulls in
 * only compiler-provided freestanding headers (<stdint.h>, <stddef.h>) and the
 * public math header, and provides:
 *
 *   - f64u: a union for lossless type punning between double and uint64_t;
 *   - bit-field masks for sign / exponent / mantissa;
 *   - inline predicates (isnan, isinf, signbit, zero) built from raw bits so
 *     no libc is required;
 *   - inline bit extraction helpers.
 *
 * Nothing here allocates, calls out, or touches global state.
 *============================================================================*/

#ifndef ASMLIB_MATH_PRIVATE_H
#define ASMLIB_MATH_PRIVATE_H

#include <stdint.h>
#include <stddef.h>

#include "asmlib_math.h"    /* ASM_MATH() and the public prototypes */

typedef union {
    double   f;
    uint64_t u;
} f64u;

#define F64_SIGN  0x8000000000000000ULL   /* sign bit                       */
#define F64_EXP   0x7ff0000000000000ULL   /* exponent field                 */
#define F64_MANT  0x000fffffffffffffULL   /* mantissa field                 */
#define F64_HID   0x0010000000000000ULL   /* implicit leading 1             */
#define F64_ABS   0x7fffffffffffffffULL   /* everything but the sign bit    */

/* Quiet NaN with the conventional all-zero payload (matches most libms). */
#define F64_QNAN  f64_from_bits(F64_EXP | (1ULL << 51))
#define F64_INF   f64_from_bits(F64_EXP)

static inline uint64_t f64_bits(double x)
{
    f64u v;
    v.f = x;
    return v.u;
}

static inline double f64_from_bits(uint64_t u)
{
    f64u v;
    v.u = u;
    return v.f;
}

static inline int f64_signbit(double x)
{
    return (int)(f64_bits(x) >> 63);
}

/* True for a NaN of any payload. */
static inline int f64_isnan(double x)
{
    uint64_t u = f64_bits(x) & F64_ABS;
    return u > F64_EXP;
}

/* True for +Inf or -Inf. */
static inline int f64_isinf(double x)
{
    return (f64_bits(x) & F64_ABS) == F64_EXP;
}

/* True for +0.0 or -0.0. */
static inline int f64_iszero(double x)
{
    return (f64_bits(x) & F64_ABS) == 0;
}

/* Biased exponent field (0 for zero/subnormal, 0x7ff for inf/NaN). */
static inline int f64_expfield(double x)
{
    return (int)((f64_bits(x) >> 52) & 0x7ff);
}

#endif /* ASMLIB_MATH_PRIVATE_H */
