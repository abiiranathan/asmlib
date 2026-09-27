/*==============================================================================
 * str.c - portable, freestanding C string primitives
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * A plain C11 backend for the x86-64 NASM string routines, for targets where
 * the assembly cannot run (WebAssembly and other freestanding environments).
 * It implements the exact behaviour documented in src/string.asm,
 * src/strcmp.asm and src/search.asm, and declared in portable.h. No libc is
 * used; only <stddef.h>/<stdint.h> are required.
 *
 * Correctness and bounds safety take priority over speed. Every read stops at
 * the terminating NUL (or the caller-supplied length), so no routine ever
 * touches a byte it was not allowed to.
 *============================================================================*/

#include "portable.h"

typedef unsigned char byte;

/* ASCII-only case folding, matching the C/POSIX locale. */
static unsigned char fold_ascii(unsigned char c) {
    if (c >= (unsigned char)'A' && c <= (unsigned char)'Z')
        return (unsigned char)(c + ('a' - 'A'));
    return c;
}

/* Membership test for strspn/strcspn/strpbrk. The NUL terminator of `accept`
 * is never part of the set, matching the assembly implementations. */
static int byte_in_set(unsigned char c, const char *accept) {
    while (*accept != '\0') {
        if ((unsigned char)*accept == c)
            return 1;
        accept++;
    }
    return 0;
}

/*==============================================================================
 * size_t ASM_LIBC(strlen)(const char *s)
 *============================================================================*/
size_t ASM_LIBC(strlen)(const char *s) {
    const char *p = s;
    while (*p != '\0')
        p++;
    return (size_t)(p - s);
}

/*==============================================================================
 * size_t ASM_LIBC(strnlen)(const char *s, size_t maxlen)
 *============================================================================*/
size_t ASM_LIBC(strnlen)(const char *s, size_t maxlen) {
    size_t n = 0;
    while (n < maxlen && s[n] != '\0')
        n++;
    return n;
}

/*==============================================================================
 * char *ASM_LIBC(strncpy)(char *dst, const char *src, size_t n)
 *------------------------------------------------------------------------------
 * Copy at most n bytes and NUL-pad the remainder. Returns dst.
 *============================================================================*/
char *ASM_LIBC(strncpy)(char *dst, const char *src, size_t n) {
    size_t i = 0;
    for (; i < n && src[i] != '\0'; i++)
        dst[i] = src[i];
    for (; i < n; i++)
        dst[i] = '\0';
    return dst;
}

/*==============================================================================
 * char *ASM_LIBC(stpncpy)(char *dst, const char *src, size_t n)
 *------------------------------------------------------------------------------
 * Like strncpy; returns the written terminating NUL, or dst + n when src
 * filled the whole region.
 *============================================================================*/
char *ASM_LIBC(stpncpy)(char *dst, const char *src, size_t n) {
    size_t i = 0;
    for (; i < n && src[i] != '\0'; i++)
        dst[i] = src[i];
    if (i < n) {
        char *ret = dst + i;
        for (; i < n; i++)
            dst[i] = '\0';
        return ret;
    }
    return dst + n;
}

/*==============================================================================
 * char *ASM_LIBC(strncat)(char *dst, const char *src, size_t n)
 *------------------------------------------------------------------------------
 * Append at most n bytes and NUL-terminate. Returns dst.
 *============================================================================*/
char *ASM_LIBC(strncat)(char *dst, const char *src, size_t n) {
    char *d = dst + ASM_LIBC(strlen)(dst);
    size_t i = 0;
    for (; i < n && src[i] != '\0'; i++)
        d[i] = src[i];
    d[i] = '\0';
    return dst;
}

/*==============================================================================
 * size_t ASM_LIBC(strlcpy)(char *dst, const char *src, size_t size)
 *------------------------------------------------------------------------------
 * Copy at most size-1 bytes, NUL-terminate when size > 0, never write past
 * dst[size-1]. Returns strlen(src).
 *============================================================================*/
size_t ASM_LIBC(strlcpy)(char *dst, const char *src, size_t size) {
    size_t srclen = ASM_LIBC(strlen)(src);
    if (size != 0) {
        size_t copy = (srclen < size - 1) ? srclen : size - 1;
        ASM_LIBC(memcpy)(dst, src, copy);
        dst[copy] = '\0';
    }
    return srclen;
}

/*==============================================================================
 * size_t ASM_LIBC(strlcat)(char *dst, const char *src, size_t size)
 *------------------------------------------------------------------------------
 * Append at most size-strlen(dst)-1 bytes, NUL-terminate, never write past
 * dst[size-1]. Returns min(size, strlen(dst)) + strlen(src); writes nothing
 * when dst has no NUL within size.
 *============================================================================*/
size_t ASM_LIBC(strlcat)(char *dst, const char *src, size_t size) {
    size_t dlen = ASM_LIBC(strnlen)(dst, size);
    size_t slen = ASM_LIBC(strlen)(src);
    if (dlen == size)
        return size + slen;
    size_t room = size - dlen - 1;
    size_t copy = (slen < room) ? slen : room;
    ASM_LIBC(memcpy)(dst + dlen, src, copy);
    dst[dlen + copy] = '\0';
    return dlen + slen;
}

/*==============================================================================
 * int ASM_LIBC(strcmp)(const char *a, const char *b)
 *============================================================================*/
int ASM_LIBC(strcmp)(const char *a, const char *b) {
    while (*a != '\0' && *a == *b) {
        a++;
        b++;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

/*==============================================================================
 * int ASM_LIBC(strncmp)(const char *a, const char *b, size_t n)
 *============================================================================*/
int ASM_LIBC(strncmp)(const char *a, const char *b, size_t n) {
    while (n != 0 && *a != '\0' && *a == *b) {
        a++;
        b++;
        n--;
    }
    if (n == 0)
        return 0;
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

/*==============================================================================
 * int ASM_LIBC(strcasecmp)(const char *a, const char *b)
 *============================================================================*/
int ASM_LIBC(strcasecmp)(const char *a, const char *b) {
    for (;;) {
        unsigned char ca = fold_ascii((unsigned char)*a);
        unsigned char cb = fold_ascii((unsigned char)*b);
        if (ca != cb || ca == '\0')
            return (int)ca - (int)cb;
        a++;
        b++;
    }
}

/*==============================================================================
 * int ASM_LIBC(strncasecmp)(const char *a, const char *b, size_t n)
 *============================================================================*/
int ASM_LIBC(strncasecmp)(const char *a, const char *b, size_t n) {
    while (n != 0) {
        unsigned char ca = fold_ascii((unsigned char)*a);
        unsigned char cb = fold_ascii((unsigned char)*b);
        if (ca != cb || ca == '\0')
            return (int)ca - (int)cb;
        a++;
        b++;
        n--;
    }
    return 0;
}

/*==============================================================================
 * char *ASM_LIBC(strchr)(const char *s, int c)
 *------------------------------------------------------------------------------
 * First occurrence of (char)c, including the NUL when c == 0, or NULL.
 *============================================================================*/
char *ASM_LIBC(strchr)(const char *s, int c) {
    unsigned char uc = (unsigned char)c;
    for (;;) {
        if ((unsigned char)*s == uc)
            return (char *)s;
        if (*s == '\0')
            return NULL;
        s++;
    }
}

/*==============================================================================
 * char *ASM_LIBC(strrchr)(const char *s, int c)
 *------------------------------------------------------------------------------
 * Last occurrence of (char)c, including the NUL when c == 0, or NULL.
 *============================================================================*/
char *ASM_LIBC(strrchr)(const char *s, int c) {
    unsigned char uc = (unsigned char)c;
    const char *last = NULL;
    for (;;) {
        if ((unsigned char)*s == uc)
            last = s;
        if (*s == '\0')
            break;
        s++;
    }
    return (char *)last;
}

/*==============================================================================
 * char *ASM_LIBC(strstr)(const char *hay, const char *needle)
 *------------------------------------------------------------------------------
 * First occurrence of needle inside hay, or NULL. Empty needle returns hay.
 *============================================================================*/
char *ASM_LIBC(strstr)(const char *hay, const char *needle) {
    if (*needle == '\0')
        return (char *)hay;
    for (; *hay != '\0'; hay++) {
        const char *h = hay;
        const char *n = needle;
        while (*h != '\0' && *n != '\0' && *h == *n) {
            h++;
            n++;
        }
        if (*n == '\0')
            return (char *)hay;
    }
    return NULL;
}

/*==============================================================================
 * void *ASM_LIBC(memmem)(const void *hay, size_t hlen,
 *                         const void *needle, size_t nlen)
 *------------------------------------------------------------------------------
 * First occurrence of needle[0..nlen) inside hay[0..hlen), or NULL. An empty
 * needle returns hay.
 *============================================================================*/
void *ASM_LIBC(memmem)(const void *hay, size_t hlen, const void *needle, size_t nlen) {
    const byte *h = (const byte *)hay;
    const byte *n = (const byte *)needle;

    if (nlen == 0)
        return (void *)hay;
    if (nlen > hlen)
        return NULL;
    for (size_t i = 0; i <= hlen - nlen; i++) {
        size_t j = 0;
        while (j < nlen && h[i + j] == n[j])
            j++;
        if (j == nlen)
            return (void *)(h + i);
    }
    return NULL;
}

/*==============================================================================
 * size_t ASM_LIBC(strspn)(const char *s, const char *accept)
 *------------------------------------------------------------------------------
 * Length of the initial segment of s made only of bytes from accept.
 *============================================================================*/
size_t ASM_LIBC(strspn)(const char *s, const char *accept) {
    size_t n = 0;
    while (s[n] != '\0' && byte_in_set((unsigned char)s[n], accept))
        n++;
    return n;
}

/*==============================================================================
 * size_t ASM_LIBC(strcspn)(const char *s, const char *accept)
 *------------------------------------------------------------------------------
 * Length of the initial segment of s made only of bytes NOT in accept.
 *============================================================================*/
size_t ASM_LIBC(strcspn)(const char *s, const char *accept) {
    size_t n = 0;
    while (s[n] != '\0' && !byte_in_set((unsigned char)s[n], accept))
        n++;
    return n;
}

/*==============================================================================
 * char *ASM_LIBC(strpbrk)(const char *s, const char *accept)
 *------------------------------------------------------------------------------
 * First byte of s that occurs in accept, or NULL.
 *============================================================================*/
char *ASM_LIBC(strpbrk)(const char *s, const char *accept) {
    for (; *s != '\0'; s++) {
        if (byte_in_set((unsigned char)*s, accept))
            return (char *)s;
    }
    return NULL;
}
