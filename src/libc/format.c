/*==============================================================================
 * format.c - portable C integer-to-string + minimal snprintf backend
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Freestanding C implementation of the asmlib formatting helpers, used on
 * wasm32 and other targets where the hand-written assembly does not run. It
 * matches the subset documented in include/asmlib.h exactly: %%, %c, %s, %p,
 * %d, %i, %u, %x, %X and %o with the '-'/'0' flags, a decimal width and the
 * l/ll length modifiers. No libc, no libm, no floating point.
 *============================================================================*/

#include <stdarg.h>
#include <stddef.h>

#include "portable.h"

typedef unsigned long long u64;
typedef long long i64;

#define FLAG_LEFT 1u
#define FLAG_ZERO 2u

static const char L_digits_lc[] = "0123456789abcdefghijklmnopqrstuvwxyz";
static const char L_digits_uc[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/*------------------------------------------------------------------------------
 * Digit generation and bounded output
 *----------------------------------------------------------------------------*/
static size_t L_gen_digits(u64 v, char *out, unsigned base, int upper) {
    const char *d = upper ? L_digits_uc : L_digits_lc;
    char tmp[72];
    size_t n = 0, i;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = d[v % base]; v /= base; }
    for (i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
    return n;
}

static size_t L_emit_bounded(const char *full, size_t len, char *buf, size_t cap) {
    size_t n = cap ? cap - 1 : 0;
    if (n > len) n = len;
    for (size_t i = 0; i < n; i++) buf[i] = full[i];
    if (cap) buf[n] = 0;
    return len;
}

size_t asm_u64toa_base(u64 value, char *buf, size_t cap, unsigned base) {
    char tmp[72];
    size_t n;
    if (base < 2 || base > 36) { if (cap) buf[0] = 0; return 0; }
    n = L_gen_digits(value, tmp, base, 0);
    return L_emit_bounded(tmp, n, buf, cap);
}

size_t asm_u64toa(u64 value, char *buf, size_t cap) {
    return asm_u64toa_base(value, buf, cap, 10);
}

size_t asm_u64tohex(u64 value, char *buf, size_t cap, int uppercase) {
    char tmp[72];
    size_t n = L_gen_digits(value, tmp, 16, uppercase != 0);
    return L_emit_bounded(tmp, n, buf, cap);
}

size_t asm_i64toa(i64 value, char *buf, size_t cap) {
    char full[80];
    size_t n = 0;
    u64 mag;
    if (value < 0) {
        full[n++] = '-';
        mag = (u64)(-(value + 1)) + 1;      /* INT64_MIN-safe magnitude */
    } else {
        mag = (u64)value;
    }
    n += L_gen_digits(mag, full + n, 10, 0);
    return L_emit_bounded(full, n, buf, cap);
}

/*------------------------------------------------------------------------------
 * Minimal snprintf
 *----------------------------------------------------------------------------*/
struct sink {
    char *cur;
    char *limit;                            /* last writable byte, or cur-1 */
    size_t count;                           /* would-be length */
};

static void putc_(struct sink *s, char c) {
    s->count++;
    if (s->cur <= s->limit) *s->cur++ = c;
}

static void putn_(struct sink *s, const char *p, size_t n) {
    s->count += n;
    while (n && s->cur <= s->limit) { *s->cur++ = *p++; n--; }
}

static void putrep_(struct sink *s, char c, size_t n) {
    s->count += n;
    while (n && s->cur <= s->limit) { *s->cur++ = c; n--; }
}

static void emit_padded(struct sink *s, const char *pre, size_t prelen,
                        const char *dig, size_t diglen, size_t width,
                        unsigned flags, int numeric) {
    size_t content = prelen + diglen;
    size_t pad = width > content ? width - content : 0;
    if (flags & FLAG_LEFT) {
        putn_(s, pre, prelen);
        putn_(s, dig, diglen);
        putrep_(s, ' ', pad);
    } else if (numeric && (flags & FLAG_ZERO)) {
        putn_(s, pre, prelen);
        putrep_(s, '0', pad);
        putn_(s, dig, diglen);
    } else {
        putrep_(s, ' ', pad);
        putn_(s, pre, prelen);
        putn_(s, dig, diglen);
    }
}

int ASM_LIBC(snprintf)(char *dst, size_t size, const char *fmt, ...) {
    struct sink s;
    va_list ap;
    char digits[80];

    s.cur = dst;
    s.limit = (size ? dst + size - 1 : dst) - 1; /* no store when size == 0 */
    if (size == 0) s.limit = dst - 1;
    s.count = 0;

    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        unsigned flags = 0;
        size_t width = 0;
        int is64 = 0;
        char conv;
        if (*fmt != '%') { putc_(&s, *fmt); continue; }
        fmt++;
        while (*fmt == '-' || *fmt == '0') {
            flags |= (*fmt == '-') ? FLAG_LEFT : FLAG_ZERO;
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (size_t)(*fmt - '0');
            if (width > 0x7fffffffu) width = 0x7fffffffu;
            fmt++;
        }
        if (*fmt == 'l') { is64 = 1; fmt++; if (*fmt == 'l') fmt++; }
        conv = *fmt;
        if (conv == 0) break;               /* trailing '%' */

        if (conv == '%') {
            putc_(&s, '%');
        } else if (conv == 'c') {
            char buf[1];
            buf[0] = (char)va_arg(ap, int);
            emit_padded(&s, NULL, 0, buf, 1, width, flags, 0);
        } else if (conv == 's') {
            const char *str = va_arg(ap, const char *);
            size_t n;
            if (!str) str = "(null)";
            for (n = 0; str[n]; n++) { }
            emit_padded(&s, NULL, 0, str, n, width, flags, 0);
        } else if (conv == 'p') {
            void *ptr = va_arg(ap, void *);
            if (!ptr) {
                emit_padded(&s, NULL, 0, "(nil)", 5, width, flags, 0);
            } else {
                size_t n = L_gen_digits((u64)(size_t)ptr, digits, 16, 0);
                emit_padded(&s, "0x", 2, digits, n, width, flags, 1);
            }
        } else if (conv == 'd' || conv == 'i') {
            i64 v = is64 ? va_arg(ap, i64) : (i64)va_arg(ap, int);
            u64 mag;
            char pre[1];
            size_t prelen = 0;
            size_t n;
            if (v < 0) { pre[0] = '-'; prelen = 1; mag = (u64)(-(v + 1)) + 1; }
            else mag = (u64)v;
            n = L_gen_digits(mag, digits, 10, 0);
            emit_padded(&s, pre, prelen, digits, n, width, flags, 1);
        } else if (conv == 'u' || conv == 'x' || conv == 'X' || conv == 'o') {
            u64 v = is64 ? va_arg(ap, u64) : (u64)va_arg(ap, unsigned);
            unsigned base = (conv == 'u') ? 10 : (conv == 'o') ? 8 : 16;
            int upper = (conv == 'X');
            size_t n = L_gen_digits(v, digits, base, upper);
            emit_padded(&s, NULL, 0, digits, n, width, flags, 1);
        } else {
            /* unsupported: copy '%' and the specifier literally */
            putc_(&s, '%');
            putc_(&s, conv);
        }
    }
    va_end(ap);

    if (size) *s.cur = 0;
    return (int)s.count;
}
