/*==============================================================================
 * scan.c - portable C minimal sscanf backend
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Freestanding C implementation of asm_sscanf, used on wasm32 and other targets
 * where the assembly backends do not run. Matches the subset in
 * include/asmlib.h: %%, %c, %s, %p, %d, %i, %u, %x, %X and %o with '*', a
 * decimal width and the l/ll length modifiers. %s requires a width unless
 * suppressed. No libc, no floating point.
 *============================================================================*/

#include <stdarg.h>
#include <stddef.h>

#include "portable.h"

typedef unsigned long long u64;
typedef long long i64;

#define F_SUPP 1u
#define F_64   2u

static int is_ws(unsigned char c) { return c == ' ' || (c >= 9 && c <= 13); }

static void store32(void *p, unsigned v) {
    unsigned char *b = (unsigned char *)p;
    b[0] = (unsigned char)v;
    b[1] = (unsigned char)(v >> 8);
    b[2] = (unsigned char)(v >> 16);
    b[3] = (unsigned char)(v >> 24);
}
static void store64(void *p, u64 v) {
    unsigned char *b = (unsigned char *)p;
    for (int i = 0; i < 8; i++) b[i] = (unsigned char)(v >> (8 * i));
}

static const char *skip_ws(const char *s) {
    while (is_ws((unsigned char)*s)) s++;
    return s;
}

/* Parse an unsigned field of `base`, at most `limit` characters; saturate at
 * `cap`. Returns the new cursor; sets *ndig (digits seen) and *sat. */
static const char *parse_digits(const char *s, size_t limit, unsigned base,
                                u64 cap, u64 *out, int *ndig, int *sat) {
    u64 v = 0;
    int n = 0;
    *sat = 0;
    for (size_t i = 0; i < limit; i++) {
        unsigned char c = (unsigned char)*s;
        unsigned dv;
        if (c >= '0' && c <= '9') dv = (unsigned)(c - '0');
        else if (base == 16 && ((c | 0x20) >= 'a' && (c | 0x20) <= 'f'))
            dv = (unsigned)((c | 0x20) - 'a' + 10);
        else break;
        if (dv >= base) break;
        if (v > (~(u64)0 - dv) / base) {
            v = cap;
            *sat = 1;
        } else {
            u64 nv = v * base + dv;
            if (nv > cap) { v = cap; *sat = 1; }
            else v = nv;
        }
        s++;
        n++;
    }
    *out = v;
    *ndig = n;
    return s;
}

int ASM_LIBC(sscanf)(const char *src, const char *fmt, ...) {
    const char *s = src;
    const char *f = fmt;
    int count = 0;
    int eof = 0;
    va_list ap;
    va_start(ap, fmt);

    while (*f) {
        char fc = *f++;
        if (fc != '%') {
            if (is_ws((unsigned char)fc)) { s = skip_ws(s); continue; }
            if (*s != fc) { if (!*s) eof = 1; goto stop; }
            s++;
            continue;
        }
        unsigned flags = 0;
        size_t width = 0;
        int is_signed = 0;
        unsigned base = 0;
        char conv;
        if (*f == '*') { flags |= F_SUPP; f++; }
        while (*f >= '0' && *f <= '9') { width = width * 10 + (size_t)(*f - '0'); f++; }
        if (*f == 'l') { flags |= F_64; f++; if (*f == 'l') f++; }
        conv = *f;
        if (!conv) break;
        f++;

        if (conv == '%') {
            if (*s != '%') { if (!*s) eof = 1; goto stop; }
            s++;
            continue;
        }
        if (conv == 'c') {
            size_t n = width ? width : 1;
            char *dst = (flags & F_SUPP) ? NULL : (char *)va_arg(ap, void *);
            for (size_t i = 0; i < n; i++) {
                if (!*s) { eof = 1; goto stop; }
                if (dst) dst[i] = *s;
                s++;
            }
            if (!(flags & F_SUPP)) count++;
            continue;
        }
        if (conv == 's') {
            size_t n = width;
            char *dst;
            size_t got = 0;
            if (!n) {
                if (!(flags & F_SUPP)) { count = -1; goto done; }
                n = (size_t)-1;
            }
            dst = (flags & F_SUPP) ? NULL : (char *)va_arg(ap, void *);
            s = skip_ws(s);
            while (n && *s && !is_ws((unsigned char)*s)) {
                if (dst) dst[got] = *s;
                s++;
                n--;
                got++;
            }
            if (!got) { if (!*s) eof = 1; goto stop; }
            if (dst) dst[got] = 0;
            if (!(flags & F_SUPP)) count++;
            continue;
        }

        /* ---- integers / pointers ---- */
        if (conv == 'd' || conv == 'i') { is_signed = 1; base = 10; }
        else if (conv == 'u') base = 10;
        else if (conv == 'x' || conv == 'X') base = 16;
        else if (conv == 'o') base = 8;
        else if (conv == 'p') { base = 16; flags |= F_64; }
        else { count = -1; goto done; }          /* unsupported */

        {
            const char *start = skip_ws(s);
            size_t left = width ? width : ~(size_t)0;
            int neg = 0, ndig = 0, sat = 0;
            u64 cap, mag;
            void *dst;
            s = start;
            if (left && (*s == '+' || *s == '-')) { neg = (*s == '-'); s++; left--; }
            if (conv == 'i') {
                if (base == 10 && left >= 1 && s[0] == '0') {
                    if (left >= 2 && (s[1] | 0x20) == 'x') { base = 16; s += 2; left -= 2; }
                    else { base = 8; }
                }
            } else if (base == 16) {
                if (left >= 2 && s[0] == '0' && (s[1] | 0x20) == 'x') { s += 2; left -= 2; }
            }
            if (is_signed) cap = neg ? 0x8000000000000000ULL : 0x7fffffffffffffffULL;
            else cap = ~(u64)0;
            s = parse_digits(s, left, base, cap, &mag, &ndig, &sat);
            if (!ndig) {
                if (s == start && !*s) eof = 1;
                goto stop;
            }
            if (neg && !(sat && !is_signed)) mag = (u64)(-(i64)mag);
            if (flags & F_SUPP) continue;
            dst = va_arg(ap, void *);
            if (flags & F_64) store64(dst, mag);
            else store32(dst, (unsigned)mag);
            count++;
            continue;
        }
    }
    goto done;

stop:
    if (count == 0 && eof) count = -1;
done:
    va_end(ap);
    return count;
}
