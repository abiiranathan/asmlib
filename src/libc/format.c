/*==============================================================================
 * format.c - portable C integer-to-string backend
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Freestanding C implementation of the bounded integer-to-string converters,
 * used on wasm32 and other targets where the hand-written assembly does not run.
 * The full formatted-output engine lives in printf.c.
 *============================================================================*/

#include <stddef.h>

#include "portable.h"

typedef unsigned long long u64;
typedef long long i64;

static const char L_digits_lc[] = "0123456789abcdefghijklmnopqrstuvwxyz";

static size_t L_gen_digits(u64 v, char *out, unsigned base, int upper) {
    const char *d = upper ? "0123456789ABCDEF" : L_digits_lc;
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
