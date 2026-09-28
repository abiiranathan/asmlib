/*==============================================================================
 * dispatch.c - runtime AVX2 -> scalar fallback for the x86-64 hot routines
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * One coherent API: every public memory/string/comparison/search entry point
 * forwards to the hand-written AVX2 implementation when the CPU supports it and
 * to the portable scalar implementation otherwise. The choice is made once,
 * lazily, on the first call — no error, no environment variable, no separate
 * library needed. The scalar half is the same code the wasm build uses.
 *
 * On non-x86-64 targets there is nothing to dispatch: asmlib.h resolves to the
 * single native implementation and this file is not built. The hosted Linux
 * x86-64 build uses dispatch_ifunc.c (ELF IFUNC) instead of this file.
 *============================================================================*/

#ifndef ASMLIB_DISPATCH_IFUNC

#include "asmlib.h"

#include <stddef.h>

extern int asm_cpu_has_avx2(void);

/* -1 = not probed yet, 0 = scalar, 1 = AVX2. A benign race on first use: both
 * threads compute the same value from CPUID. */
static int asm_dispatch_state = -1;

static int asm_use_avx2(void) {
    int s = asm_dispatch_state;
    if (s < 0) {
        s = asm_cpu_has_avx2() ? 1 : 0;
        asm_dispatch_state = s;
    }
    return s;
}

#define DISPATCH_R(ret, name, params, args)                                  \
    extern ret asm_avx2_asm_##name params;                                   \
    extern ret asm_scalar_##name params;                                 \
    ret asm_##name params {                                                  \
        return asm_use_avx2() ? asm_avx2_asm_##name args                     \
                              : asm_scalar_##name args;                  \
    }

#define DISPATCH_V(name, params, args)                                       \
    extern void asm_avx2_asm_##name params;                                  \
    extern void asm_scalar_##name params;                                \
    void asm_##name params {                                                 \
        if (asm_use_avx2()) asm_avx2_asm_##name args;                        \
        else asm_scalar_##name args;                                     \
    }

/* ---- memory ------------------------------------------------------------ */
DISPATCH_R(void *, memcpy, (void *d, const void *s, size_t n), (d, s, n))
DISPATCH_R(void *, mempcpy, (void *d, const void *s, size_t n), (d, s, n))
DISPATCH_R(void *, memccpy, (void *d, const void *s, int c, size_t n), (d, s, c, n))
DISPATCH_R(void *, memmove, (void *d, const void *s, size_t n), (d, s, n))
DISPATCH_R(void *, memset, (void *d, int c, size_t n), (d, c, n))
DISPATCH_R(void *, bzero, (void *d, size_t n), (d, n))
DISPATCH_V(explicit_bzero, (void *d, size_t n), (d, n))
DISPATCH_R(int, memcmp, (const void *a, const void *b, size_t n), (a, b, n))
DISPATCH_R(void *, memchr, (const void *s, int c, size_t n), (s, c, n))
DISPATCH_R(void *, memrchr, (const void *s, int c, size_t n), (s, c, n))

/* ---- string ------------------------------------------------------------ */
DISPATCH_R(size_t, strlen, (const char *s), (s))
DISPATCH_R(size_t, strnlen, (const char *s, size_t m), (s, m))
DISPATCH_R(char *, strncpy, (char *d, const char *s, size_t n), (d, s, n))
DISPATCH_R(char *, stpncpy, (char *d, const char *s, size_t n), (d, s, n))
DISPATCH_R(char *, strncat, (char *d, const char *s, size_t n), (d, s, n))
DISPATCH_R(size_t, strlcpy, (char *d, const char *s, size_t n), (d, s, n))
DISPATCH_R(size_t, strlcat, (char *d, const char *s, size_t n), (d, s, n))

/* ---- comparison -------------------------------------------------------- */
DISPATCH_R(int, strcmp, (const char *a, const char *b), (a, b))
DISPATCH_R(int, strncmp, (const char *a, const char *b, size_t n), (a, b, n))
DISPATCH_R(int, strcasecmp, (const char *a, const char *b), (a, b))
DISPATCH_R(int, strncasecmp, (const char *a, const char *b, size_t n), (a, b, n))

/* ---- searching --------------------------------------------------------- */
DISPATCH_R(char *, strchr, (const char *s, int c), (s, c))
DISPATCH_R(char *, strrchr, (const char *s, int c), (s, c))
DISPATCH_R(char *, strstr, (const char *h, const char *n), (h, n))
DISPATCH_R(void *, memmem, (const void *h, size_t hn, const void *n, size_t nn), (h, hn, n, nn))
DISPATCH_R(size_t, strspn, (const char *s, const char *a), (s, a))
DISPATCH_R(size_t, strcspn, (const char *s, const char *a), (s, a))
DISPATCH_R(char *, strpbrk, (const char *s, const char *a), (s, a))

#endif /* !ASMLIB_DISPATCH_IFUNC */
