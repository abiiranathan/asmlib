/*==============================================================================
 * mem.c - portable, freestanding C memory primitives
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * A plain C11 backend for the x86-64 NASM memory routines, for targets where
 * the assembly cannot run (WebAssembly and other freestanding environments).
 * It implements the exact behaviour documented in src/memory.asm and declared
 * in portable.h. No libc is used; only <stddef.h>/<stdint.h> are required.
 *
 * Correctness and bounds safety take priority over speed, but the bulk copy
 * and fill routines process one machine word at a time whenever the two
 * pointers share an alignment, and every path stays strictly inside the
 * caller-requested range.
 *============================================================================*/

#include "portable.h"
#include <stdint.h>

typedef unsigned char byte;

/* An aliasable, pointer-sized integer used for word-at-a-time bulk moves. */
#if defined(__GNUC__) || defined(__clang__)
typedef uintptr_t __attribute__((__may_alias__)) word;
#else
typedef uintptr_t word;
#endif

#define WORD_BYTES (sizeof(word))
#define WORD_MASK  ((uintptr_t)(WORD_BYTES - 1u))

/*==============================================================================
 * void *ASM_LIBC(memcpy)(void *dst, const void *src, size_t n)
 *------------------------------------------------------------------------------
 * Copy exactly n bytes; dst and src must not overlap. Returns dst.
 *============================================================================*/
void *ASM_LIBC(memcpy)(void *dst, const void *src, size_t n) {
    byte *d = (byte *)dst;
    const byte *s = (const byte *)src;

    /* Word-at-a-time only when both pointers have the same misalignment. */
    if ((((uintptr_t)d ^ (uintptr_t)s) & WORD_MASK) == 0) {
        while (n != 0 && ((uintptr_t)d & WORD_MASK) != 0) {
            *d++ = *s++;
            n--;
        }
        if (n >= WORD_BYTES) {
            word *dw = (word *)(void *)d;
            const word *sw = (const word *)(const void *)s;
            do {
                *dw++ = *sw++;
                n -= WORD_BYTES;
            } while (n >= WORD_BYTES);
            d = (byte *)dw;
            s = (const byte *)sw;
        }
    }
    while (n != 0) {
        *d++ = *s++;
        n--;
    }
    return dst;
}

/*==============================================================================
 * void *ASM_LIBC(memmove)(void *dst, const void *src, size_t n)
 *------------------------------------------------------------------------------
 * Copy n bytes; the regions may overlap. Returns dst.
 *============================================================================*/
void *ASM_LIBC(memmove)(void *dst, const void *src, size_t n) {
    byte *d = (byte *)dst;
    const byte *s = (const byte *)src;

    if (d == s || n == 0)
        return dst;
    if ((uintptr_t)d < (uintptr_t)s || (uintptr_t)d >= (uintptr_t)s + n)
        return ASM_LIBC(memcpy)(dst, src, n);
    /* dst > src and overlapping: copy strictly from high to low. */
    while (n != 0) {
        n--;
        d[n] = s[n];
    }
    return dst;
}

/*==============================================================================
 * void *ASM_LIBC(mempcpy)(void *dst, const void *src, size_t n)
 *------------------------------------------------------------------------------
 * Copy n bytes and return dst + n.
 *============================================================================*/
void *ASM_LIBC(mempcpy)(void *dst, const void *src, size_t n) {
    ASM_LIBC(memcpy)(dst, src, n);
    return (byte *)dst + n;
}

/*==============================================================================
 * void *ASM_LIBC(memccpy)(void *dst, const void *src, int c, size_t n)
 *------------------------------------------------------------------------------
 * Copy bytes until (unsigned char)c has been copied or n bytes have been
 * copied. Returns a pointer just past the copied c, or NULL when c is absent.
 *============================================================================*/
void *ASM_LIBC(memccpy)(void *dst, const void *src, int c, size_t n) {
    byte *d = (byte *)dst;
    const byte *s = (const byte *)src;
    unsigned char uc = (unsigned char)c;

    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
        if (s[i] == uc)
            return d + i + 1;
    }
    return NULL;
}

/*==============================================================================
 * void *ASM_LIBC(memset)(void *dst, int c, size_t n)
 *------------------------------------------------------------------------------
 * Fill n bytes with the low byte of c. Returns dst.
 *============================================================================*/
void *ASM_LIBC(memset)(void *dst, int c, size_t n) {
    byte *d = (byte *)dst;
    unsigned char uc = (unsigned char)c;

    while (n != 0 && ((uintptr_t)d & WORD_MASK) != 0) {
        *d++ = uc;
        n--;
    }
    if (n >= WORD_BYTES) {
        word w = (word)0;
        for (size_t k = 0; k < WORD_BYTES; k++)
            w = (word)((w << 8) | uc);
        word *dw = (word *)(void *)d;
        do {
            *dw++ = w;
            n -= WORD_BYTES;
        } while (n >= WORD_BYTES);
        d = (byte *)dw;
    }
    while (n != 0) {
        *d++ = uc;
        n--;
    }
    return dst;
}

/*==============================================================================
 * void *ASM_LIBC(bzero)(void *dst, size_t n)
 *------------------------------------------------------------------------------
 * Zero n bytes. Returns dst.
 *============================================================================*/
void *ASM_LIBC(bzero)(void *dst, size_t n) {
    return ASM_LIBC(memset)(dst, 0, n);
}

/*==============================================================================
 * void ASM_LIBC(explicit_bzero)(void *dst, size_t n)
 *------------------------------------------------------------------------------
 * Zero n bytes with volatile stores so the optimiser cannot remove them.
 *============================================================================*/
void ASM_LIBC(explicit_bzero)(void *dst, size_t n) {
    volatile byte *p = (volatile byte *)dst;
    while (n != 0) {
        *p++ = 0;
        n--;
    }
}

/*==============================================================================
 * int ASM_LIBC(memcmp)(const void *a, const void *b, size_t n)
 *------------------------------------------------------------------------------
 * Compare n bytes as unsigned. Returns <0, 0 or >0 for the first difference.
 *============================================================================*/
int ASM_LIBC(memcmp)(const void *a, const void *b, size_t n) {
    const byte *pa = (const byte *)a;
    const byte *pb = (const byte *)b;

    for (size_t i = 0; i < n; i++) {
        if (pa[i] != pb[i])
            return (int)pa[i] - (int)pb[i];
    }
    return 0;
}

/*==============================================================================
 * void *ASM_LIBC(memchr)(const void *s, int c, size_t n)
 *------------------------------------------------------------------------------
 * First byte equal to (unsigned char)c within n bytes, or NULL.
 *============================================================================*/
void *ASM_LIBC(memchr)(const void *s, int c, size_t n) {
    const byte *p = (const byte *)s;
    unsigned char uc = (unsigned char)c;

    for (size_t i = 0; i < n; i++) {
        if (p[i] == uc)
            return (void *)(p + i);
    }
    return NULL;
}

/*==============================================================================
 * void *ASM_LIBC(memrchr)(const void *s, int c, size_t n)
 *------------------------------------------------------------------------------
 * Last byte equal to (unsigned char)c within n bytes, or NULL.
 *============================================================================*/
void *ASM_LIBC(memrchr)(const void *s, int c, size_t n) {
    const byte *p = (const byte *)s;
    unsigned char uc = (unsigned char)c;

    for (size_t i = n; i != 0; i--) {
        if (p[i - 1] == uc)
            return (void *)(p + (i - 1));
    }
    return NULL;
}
