/*==============================================================================
 * dispatch_ifunc.c - ELF IFUNC dispatch for the x86-64 hot routines
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Same idea as dispatch.c, but the selection is made once by the loader via an
 * ELF indirect function (STT_GNU_IFUNC) instead of a branch on every call. Each
 * public asm_* symbol is defined here as an IFUNC whose resolver returns the
 * AVX2 or scalar implementation depending on the CPU. There is no per-call
 * cost and no probe on the hot path.
 *
 * The resolver runs during relocation processing (before main), so it only uses
 * asm_cpu_has_avx2() — CPUID/XGETBV, no libc and no initialised data. This file
 * is only built on hosted Linux x86-64 with GCC/Clang; the freestanding and
 * scalar builds use dispatch.c or the portable backend directly.
 *============================================================================*/

#include <stddef.h>

extern int asm_cpu_has_avx2(void);

#define RESOLVE(ret, name, params)                                           \
    extern ret asm_avx2_asm_##name params;                                   \
    extern ret asm_scalar_##name params;                                     \
    static ret (*asm_ifunc_##name(void)) params {                            \
        return asm_cpu_has_avx2() ? asm_avx2_asm_##name                      \
                                  : asm_scalar_##name;                       \
    }                                                                        \
    extern ret asm_##name params __attribute__((ifunc("asm_ifunc_" #name)))

/* ---- memory ---- */
RESOLVE(void *, memcpy, (void *, const void *, size_t));
RESOLVE(void *, mempcpy, (void *, const void *, size_t));
RESOLVE(void *, memccpy, (void *, const void *, int, size_t));
RESOLVE(void *, memmove, (void *, const void *, size_t));
RESOLVE(void *, memset, (void *, int, size_t));
RESOLVE(void *, bzero, (void *, size_t));
RESOLVE(void, explicit_bzero, (void *, size_t));
RESOLVE(int, memcmp, (const void *, const void *, size_t));
RESOLVE(void *, memchr, (const void *, int, size_t));
RESOLVE(void *, memrchr, (const void *, int, size_t));

/* ---- string ---- */
RESOLVE(size_t, strlen, (const char *));
RESOLVE(size_t, strnlen, (const char *, size_t));
RESOLVE(char *, strncpy, (char *, const char *, size_t));
RESOLVE(char *, stpncpy, (char *, const char *, size_t));
RESOLVE(char *, strncat, (char *, const char *, size_t));
RESOLVE(size_t, strlcpy, (char *, const char *, size_t));
RESOLVE(size_t, strlcat, (char *, const char *, size_t));

/* ---- comparison ---- */
RESOLVE(int, strcmp, (const char *, const char *));
RESOLVE(int, strncmp, (const char *, const char *, size_t));
RESOLVE(int, strcasecmp, (const char *, const char *));
RESOLVE(int, strncasecmp, (const char *, const char *, size_t));

/* ---- searching ---- */
RESOLVE(char *, strchr, (const char *, int));
RESOLVE(char *, strrchr, (const char *, int));
RESOLVE(char *, strstr, (const char *, const char *));
RESOLVE(void *, memmem, (const void *, size_t, const void *, size_t));
RESOLVE(size_t, strspn, (const char *, const char *));
RESOLVE(size_t, strcspn, (const char *, const char *));
RESOLVE(char *, strpbrk, (const char *, const char *));
