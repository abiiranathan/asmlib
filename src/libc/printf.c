/*==============================================================================
 * format.c - portable C full printf + integer-to-string backend
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Freestanding C implementation of the asmlib formatting helpers, used on
 * wasm32 and other targets where the hand-written assembly does not run. It
 * implements the C99 printf surface:
 *
 *   int asm_snprintf (char *dst, size_t size, const char *fmt, ...);
 *   int asm_vsnprintf(char *dst, size_t size, const char *fmt, va_list ap);
 *   int asm_sprintf  (char *dst, const char *fmt, ...);
 *   int asm_vsprintf (char *dst, const char *fmt, va_list ap);
 *   int asm_asprintf (char **strp, const char *fmt, ...);
 *   int asm_vasprintf(char **strp, const char *fmt, va_list ap);
 *
 * plus the bounded integer-to-string converters. No libc, no libm: floating
 * point is converted with a self-contained, correctly-rounded binary-to-decimal
 * routine (round half to even) built on a small fixed-width big integer.
 *============================================================================*/

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include "portable.h"

typedef unsigned long long u64;
typedef long long i64;

/* `long double` is binary128 on wasm32 and AArch64, so `%L` narrowing drags in
 * compiler soft-float helpers (e.g. __trunctfdf2) that a freestanding/no-import
 * build does not have. Those targets treat the argument as a double instead;
 * x86-64 uses the real x87 `long double` (the conversion is inline). The format
 * engine narrows `%L` to double either way. */
#if defined(__wasm__) || defined(__aarch64__)
typedef double asm_ldouble;
#else
typedef long double asm_ldouble;
#endif

#define F_LEFT  0x01u
#define F_PLUS  0x02u
#define F_SPACE 0x04u
#define F_ALT   0x08u
#define F_ZERO  0x10u

enum {
    LEN_INT, LEN_HH, LEN_H, LEN_L, LEN_LL, LEN_Z, LEN_J, LEN_T, LEN_CAP_L
};

/*------------------------------------------------------------------------------
 * Local freestanding helpers
 *----------------------------------------------------------------------------*/
static size_t s_len(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

static void s_copy(char *d, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) d[i] = s[i];
}

static void s_fill(char *d, char c, size_t n) {
    for (size_t i = 0; i < n; i++) d[i] = c;
}

/*------------------------------------------------------------------------------
 * Output sink: a callback counts and stores bytes
 *----------------------------------------------------------------------------*/
typedef struct {
    void (*emit)(void *ctx, const char *s, size_t n);
    void *ctx;
    size_t count;
} out_t;

static void o_putn(out_t *o, const char *s, size_t n) {
    if (n) { o->emit(o->ctx, s, n); o->count += n; }
}
static void o_putc(out_t *o, char c) { o->emit(o->ctx, &c, 1); o->count++; }
static void o_pad(out_t *o, char c, size_t n) {
    char b[64];
    s_fill(b, c, sizeof b);
    while (n) {
        size_t k = n < sizeof b ? n : sizeof b;
        o_putn(o, b, k);
        n -= k;
    }
}

/*------------------------------------------------------------------------------
 * Bounded integer-to-string converters
 *----------------------------------------------------------------------------*/
static const char L_digits_lc[] = "0123456789abcdefghijklmnopqrstuvwxyz";
static const char L_digits_uc[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

static size_t L_gen_digits(u64 v, char *out, unsigned base, int upper) {
    const char *d = upper ? L_digits_uc : L_digits_lc;
    char tmp[72];
    size_t n = 0, i;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = d[v % base]; v /= base; }
    for (i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
    return n;
}

/*==============================================================================
 * Correctly-rounded binary64 -> decimal
 *------------------------------------------------------------------------------
 * A small fixed-width big integer drives exact long division of the value's
 * binary representation. Because a binary64 has a finite decimal expansion the
 * digit generation terminates by itself; formatting then rounds that exact
 * string, half to even, at the requested decimal position.
 *============================================================================*/

#define BI_LIMBS 192
#define DTOA_MAX 1100

typedef struct { int n; uint32_t w[BI_LIMBS]; } bi;

static void bi_set_u64(bi *x, u64 v) {
    x->w[0] = (uint32_t)v;
    x->w[1] = (uint32_t)(v >> 32);
    x->n = x->w[1] ? 2 : (x->w[0] ? 1 : 0);
}

static void bi_set_pow2(bi *x, int bits) {
    int limb = bits >> 5, off = bits & 31, i;
    for (i = 0; i <= limb; i++) x->w[i] = 0;
    x->w[limb] = 1u << off;
    x->n = limb + 1;
}

static int bi_is_zero(const bi *x) { return x->n == 0; }

static void bi_copy(bi *d, const bi *s) {
    d->n = s->n;
    for (int i = 0; i < s->n; i++) d->w[i] = s->w[i];
}

static int bi_cmp(const bi *a, const bi *b) {
    if (a->n != b->n) return a->n < b->n ? -1 : 1;
    for (int i = a->n - 1; i >= 0; i--)
        if (a->w[i] != b->w[i]) return a->w[i] < b->w[i] ? -1 : 1;
    return 0;
}

static void bi_sub(bi *a, const bi *b) {
    int64_t borrow = 0;
    for (int i = 0; i < a->n; i++) {
        int64_t t = (int64_t)a->w[i] - (i < b->n ? b->w[i] : 0) - borrow;
        if (t < 0) { t += (int64_t)1 << 32; borrow = 1; } else borrow = 0;
        a->w[i] = (uint32_t)t;
    }
    while (a->n > 0 && a->w[a->n - 1] == 0) a->n--;
}

static void bi_mul_small(bi *x, uint32_t m) {
    if (x->n == 0 || m == 0) { x->n = 0; return; }
    u64 carry = 0;
    for (int i = 0; i < x->n; i++) {
        u64 t = (u64)x->w[i] * m + carry;
        x->w[i] = (uint32_t)t;
        carry = t >> 32;
    }
    while (carry && x->n < BI_LIMBS) {
        x->w[x->n++] = (uint32_t)carry;
        carry >>= 32;
    }
}

static void bi_shl(bi *x, int bits) {
    int limbs = bits >> 5, off = bits & 31;
    if (x->n == 0) return;
    if (off) {
        u64 carry = 0;
        for (int i = 0; i < x->n; i++) {
            u64 t = ((u64)x->w[i] << off) | carry;
            x->w[i] = (uint32_t)t;
            carry = t >> 32;
        }
        if (carry && x->n < BI_LIMBS) x->w[x->n++] = (uint32_t)carry;
    }
    if (limbs) {
        for (int i = x->n - 1; i >= 0; i--) x->w[i + limbs] = x->w[i];
        for (int i = 0; i < limbs; i++) x->w[i] = 0;
        x->n += limbs;
    }
}

/* Generate up to `cap` exact decimal significant digits of a finite v > 0.
 * Returns the digit count; *E is the leading-digit exponent and *more is set
 * when the value has further nonzero digits beyond those produced. */
static int dtoa_exact(double v, char *d, int *E, int cap, int *more) {
    union { double d; u64 u; } bits;
    uint64_t man;
    int raw_e, e, k = 0, n = 0;
    bi R, S, t;

    bits.d = v;
    raw_e = (int)((bits.u >> 52) & 0x7FF);
    man = bits.u & ((1ull << 52) - 1);
    if (raw_e == 0) { e = -1074; bi_set_u64(&R, man); }
    else { e = raw_e - 1075; bi_set_u64(&R, man | (1ull << 52)); }

    if (e >= 0) { bi_set_u64(&S, 1); bi_shl(&R, e); }
    else { bi_set_pow2(&S, -e); }

    while (bi_cmp(&R, &S) >= 0) { bi_mul_small(&S, 10); k++; }
    for (;;) {
        bi_copy(&t, &R);
        bi_mul_small(&t, 10);
        if (bi_cmp(&t, &S) < 0) { bi_copy(&R, &t); k--; }
        else break;
    }

    *more = 0;
    for (;;) {
        int dd = 0;
        bi_mul_small(&R, 10);
        while (bi_cmp(&R, &S) >= 0) { bi_sub(&R, &S); dd++; }
        d[n++] = (char)('0' + dd);
        if (bi_is_zero(&R)) break;
        if (n >= cap) { *more = 1; break; }
    }
    *E = k - 1;
    return n;
}

/* Round the significant-digit string to `keep` digits, half to even. keep may
 * be <= 0 (rounding above the leading digit). `more` says there are further
 * nonzero digits beyond the string. Updates ndig and E. */
static void dec_round(char *d, int *ndig, int *E, int keep, int more) {
    int n = *ndig, up = 0, i;
    if (n == 0) return;
    if (keep < 0) { *ndig = 0; return; }
    if (keep == 0) {
        up = (d[0] > '5') || (d[0] == '5' && (n > 1 || more));
        if (up) { d[0] = '1'; *ndig = 1; (*E)++; }
        else *ndig = 0;
        return;
    }
    if (keep >= n) return;
    {
        int next = d[keep] - '0';
        if (next > 5) up = 1;
        else if (next == 5) {
            int rest = more;
            for (i = keep + 1; i < n && !rest; i++) if (d[i] != '0') rest = 1;
            up = rest ? 1 : ((d[keep - 1] - '0') & 1);
        }
    }
    *ndig = keep;
    if (up) {
        for (i = keep - 1; i >= 0 && d[i] == '9'; i--) d[i] = '0';
        if (i < 0) { d[0] = '1'; *ndig = 1; (*E)++; }
        else d[i]++;
    }
}

/*------------------------------------------------------------------------------
 * Integer / string / char / pointer conversions
 *----------------------------------------------------------------------------*/
static void fmt_int(out_t *o, u64 mag, unsigned base, int upper, int neg,
                    unsigned flags, int width, int prec, int has_prec) {
    char dig[72];
    char prefix[4];
    int plen = 0, dn, zpad = 0, oct_lead = 0, content, pad, i;
    int zero_flag;

    dn = (int)L_gen_digits(mag, dig, base, upper);
    if (has_prec && prec == 0 && mag == 0) dn = 0;

    if (neg) prefix[plen++] = '-';
    else if (flags & F_PLUS) prefix[plen++] = '+';
    else if (flags & F_SPACE) prefix[plen++] = ' ';

    if ((flags & F_ALT) && base == 16 && mag != 0) {
        prefix[plen++] = '0';
        prefix[plen++] = upper ? 'X' : 'x';
    }
    if ((flags & F_ALT) && base == 8 && (dn == 0 || dig[0] != '0')) oct_lead = 1;

    if (has_prec && prec > dn + oct_lead) zpad = prec - (dn + oct_lead);

    content = plen + oct_lead + zpad + dn;
    pad = width > content ? width - content : 0;
    zero_flag = (flags & F_ZERO) && !has_prec && !(flags & F_LEFT);

    if (flags & F_LEFT) {
        o_putn(o, prefix, (size_t)plen);
        if (oct_lead) o_putc(o, '0');
        o_pad(o, '0', (size_t)zpad);
        o_putn(o, dig, (size_t)dn);
        o_pad(o, ' ', (size_t)pad);
    } else if (zero_flag) {
        o_putn(o, prefix, (size_t)plen);
        if (oct_lead) o_putc(o, '0');
        for (i = 0; i < pad + zpad; i++) o_putc(o, '0');
        o_putn(o, dig, (size_t)dn);
    } else {
        o_pad(o, ' ', (size_t)pad);
        o_putn(o, prefix, (size_t)plen);
        if (oct_lead) o_putc(o, '0');
        o_pad(o, '0', (size_t)zpad);
        o_putn(o, dig, (size_t)dn);
    }
}

static void fmt_str(out_t *o, const char *s, unsigned flags, int width,
                    int prec, int has_prec) {
    size_t n = 0;
    int pad;
    if (!s) s = "(null)";
    if (has_prec) { while (n < (size_t)prec && s[n]) n++; }
    else n = s_len(s);
    pad = width > (int)n ? width - (int)n : 0;
    if (flags & F_LEFT) { o_putn(o, s, n); o_pad(o, ' ', (size_t)pad); }
    else { o_pad(o, ' ', (size_t)pad); o_putn(o, s, n); }
}

static void fmt_char(out_t *o, int c, unsigned flags, int width) {
    char ch = (char)c;
    int pad = width > 1 ? width - 1 : 0;
    if (flags & F_LEFT) { o_putc(o, ch); o_pad(o, ' ', (size_t)pad); }
    else { o_pad(o, ' ', (size_t)pad); o_putc(o, ch); }
}

/*------------------------------------------------------------------------------
 * Floating point
 *----------------------------------------------------------------------------*/
static char sign_pfx(int sign, unsigned flags) {
    if (sign) return '-';
    if (flags & F_PLUS) return '+';
    if (flags & F_SPACE) return ' ';
    return 0;
}

static void emit_specials(out_t *o, const char *s, int sign, unsigned flags,
                          int width) {
    char pc = sign_pfx(sign, flags);
    int n = (int)s_len(s) + (pc ? 1 : 0);
    int pad = width > n ? width - n : 0;
    unsigned fl = flags & ~F_ZERO;
    if (fl & F_LEFT) {
        if (pc) o_putc(o, pc);
        o_putn(o, s, s_len(s));
        o_pad(o, ' ', (size_t)pad);
    } else {
        o_pad(o, ' ', (size_t)pad);
        if (pc) o_putc(o, pc);
        o_putn(o, s, s_len(s));
    }
}

static void fmt_fixed(out_t *o, const char *d, int ndig, int E, int sign,
                      unsigned flags, int width, int prec, int alt) {
    char pc = sign_pfx(sign, flags);
    int plen = pc ? 1 : 0;
    int intlen = (ndig > 0 && E >= 0) ? E + 1 : 1;
    int dot = (prec > 0 || alt) ? 1 : 0;
    int total = plen + intlen + dot + prec;
    int pad = width > total ? width - total : 0;
    int i;

    if (!(flags & F_LEFT)) {
        if (flags & F_ZERO) {
            if (pc) o_putc(o, pc);
            for (i = 0; i < pad; i++) o_putc(o, '0');
        } else {
            o_pad(o, ' ', (size_t)pad);
            if (pc) o_putc(o, pc);
        }
    } else if (pc) {
        o_putc(o, pc);
    }

    if (ndig > 0 && E >= 0) {
        int emit = ndig < intlen ? ndig : intlen;
        o_putn(o, d, (size_t)emit);
        for (i = emit; i < intlen; i++) o_putc(o, '0');
    } else {
        o_putc(o, '0');
    }
    if (dot) {
        o_putc(o, '.');
        for (i = 1; i <= prec; i++) {
            int idx = E + i;
            if (ndig > 0 && idx >= 0 && idx < ndig) o_putc(o, d[idx]);
            else o_putc(o, '0');
        }
    }
    if (flags & F_LEFT) o_pad(o, ' ', (size_t)pad);
}

static void fmt_sci(out_t *o, const char *d, int ndig, int E, int sign,
                    unsigned flags, int width, int prec, int alt, int upper) {
    char pc = sign_pfx(sign, flags);
    int plen = pc ? 1 : 0;
    int ae = E < 0 ? -E : E;
    int ewidth = ae >= 100 ? 3 : 2;
    int dot = (prec > 0 || alt) ? 1 : 0;
    int total = plen + 1 + (dot ? 1 + prec : 0) + 2 + ewidth;
    int pad = width > total ? width - total : 0;
    int i;

    if (!(flags & F_LEFT)) {
        if (flags & F_ZERO) {
            if (pc) o_putc(o, pc);
            for (i = 0; i < pad; i++) o_putc(o, '0');
        } else {
            o_pad(o, ' ', (size_t)pad);
            if (pc) o_putc(o, pc);
        }
    } else if (pc) {
        o_putc(o, pc);
    }

    o_putc(o, ndig > 0 ? d[0] : '0');
    if (dot) {
        o_putc(o, '.');
        for (i = 1; i <= prec; i++) o_putc(o, i < ndig ? d[i] : '0');
    }
    o_putc(o, upper ? 'E' : 'e');
    o_putc(o, E < 0 ? '-' : '+');
    if (ewidth == 3) o_putc(o, (char)('0' + (ae / 100) % 10));
    o_putc(o, (char)('0' + (ae / 10) % 10));
    o_putc(o, (char)('0' + ae % 10));

    if (flags & F_LEFT) o_pad(o, ' ', (size_t)pad);
}

static void fmt_hex(out_t *o, double v, int sign, unsigned flags, int width,
                    int prec, int has_prec, int upper) {
    union { double d; u64 u; } bits;
    uint64_t man;
    int raw_e, E, lead, ndig = 0, i, dot, total, pad;
    char pc = sign_pfx(sign, flags);
    char dig[24];
    const char *dl = upper ? "0123456789ABCDEF" : "0123456789abcdef";

    bits.d = v;
    raw_e = (int)((bits.u >> 52) & 0x7FF);
    man = bits.u & ((1ull << 52) - 1);

    if (raw_e == 0 && man == 0) { E = 0; lead = 0; }
    else if (raw_e == 0) { E = -1022; lead = 0; }
    else { E = raw_e - 1023; lead = 1; }

    for (i = 0; i < 13; i++) {
        int shift = (12 - i) * 4;
        dig[i] = dl[(man >> shift) & 0xF];
    }
    ndig = 13;

    if (has_prec) {
        if (prec < 13) {
            int keep = prec;
            int drop = (13 - keep) * 4;
            int up = 0;
            if (drop > 0) {
                uint64_t rem = man & ((drop >= 64) ? ~0ull : ((1ull << drop) - 1));
                uint64_t half = 1ull << (drop - 1);
                if (rem > half) up = 1;
                else if (rem == half)
                    up = (keep > 0) ? (int)((man >> drop) & 1) : (lead & 1);
            }
            if (keep == 0) {
                if (up) lead++;
                ndig = 0;
            } else {
                man = man >> drop;
                if (up) {
                    uint64_t lim = 1ull << (4 * keep);
                    man++;
                    if (man >= lim) { man = 0; lead++; }
                }
                ndig = keep;
                for (i = 0; i < keep; i++) {
                    int shift = (keep - 1 - i) * 4;
                    dig[i] = dl[(man >> shift) & 0xF];
                }
            }
        } else {
            ndig = 13;
        }
    } else {
        while (ndig > 0 && dig[ndig - 1] == '0') ndig--;
    }

    {
        int shown = has_prec ? (prec > ndig ? prec : ndig) : ndig;
        int ae = E < 0 ? -E : E, t = ae, ew = 1;
        dot = (shown > 0 || (flags & F_ALT)) ? 1 : 0;
        while (t >= 10) { t /= 10; ew++; }
        total = (pc ? 1 : 0) + 2 + 1 + (dot ? 1 + shown : 0) + 1 + 1 + ew;
    }
    pad = width > total ? width - total : 0;

    if (!(flags & F_LEFT)) {
        if (flags & F_ZERO) {
            if (pc) o_putc(o, pc);
            for (i = 0; i < pad; i++) o_putc(o, '0');
        } else {
            o_pad(o, ' ', (size_t)pad);
            if (pc) o_putc(o, pc);
        }
    } else if (pc) {
        o_putc(o, pc);
    }
    o_putc(o, '0');
    o_putc(o, upper ? 'X' : 'x');
    o_putc(o, (char)('0' + lead));
    if (dot) {
        int shown = has_prec ? (prec > ndig ? prec : ndig) : ndig;
        o_putc(o, '.');
        for (i = 0; i < ndig; i++) o_putc(o, dig[i]);
        for (i = ndig; i < shown; i++) o_putc(o, '0');
    }
    o_putc(o, upper ? 'P' : 'p');
    o_putc(o, E < 0 ? '-' : '+');
    {
        int ae = E < 0 ? -E : E;
        if (ae >= 1000) o_putc(o, (char)('0' + (ae / 1000) % 10));
        if (ae >= 100) o_putc(o, (char)('0' + (ae / 100) % 10));
        if (ae >= 10) o_putc(o, (char)('0' + (ae / 10) % 10));
        o_putc(o, (char)('0' + ae % 10));
    }
    if (flags & F_LEFT) o_pad(o, ' ', (size_t)pad);
}

static void fmt_float(out_t *o, double v, char conv, unsigned flags, int width,
                      int prec, int has_prec) {
    int upper = (conv == 'F' || conv == 'E' || conv == 'G' || conv == 'A');
    int sign = __builtin_signbit(v) ? 1 : 0;
    char d[DTOA_MAX];
    int ndig, E, more = 0;

    if (__builtin_isnan(v)) {
        emit_specials(o, upper ? "NAN" : "nan", sign, flags, width);
        return;
    }
    if (__builtin_isinf(v)) {
        emit_specials(o, upper ? "INF" : "inf", sign, flags, width);
        return;
    }
    if (sign) v = -v;

    if (conv == 'a' || conv == 'A') { fmt_hex(o, v, sign, flags, width, prec, has_prec, upper); return; }

    if (v == 0.0) {
        d[0] = '0';
        ndig = 1;
        E = 0;
        more = 0;
    } else {
        ndig = dtoa_exact(v, d, &E, 40, &more);
    }

    if (conv == 'f' || conv == 'F') {
        int p = has_prec ? prec : 6;
        int keep = E + p + 1;
        if (more && v != 0.0 && keep + 1 > ndig) {
            int cap = keep + 2 > DTOA_MAX ? DTOA_MAX : keep + 2;
            ndig = dtoa_exact(v, d, &E, cap, &more);
        }
        dec_round(d, &ndig, &E, keep, more);
        fmt_fixed(o, d, ndig, E, sign, flags, width, p, flags & F_ALT);
    } else if (conv == 'e' || conv == 'E') {
        int p = has_prec ? prec : 6;
        int keep = p + 1;
        if (more && v != 0.0 && keep + 1 > ndig) {
            int cap = keep + 2 > DTOA_MAX ? DTOA_MAX : keep + 2;
            ndig = dtoa_exact(v, d, &E, cap, &more);
        }
        dec_round(d, &ndig, &E, keep, more);
        fmt_sci(o, d, ndig, E, sign, flags, width, p, flags & F_ALT, upper);
    } else { /* g / G */
        int P = has_prec ? (prec ? prec : 1) : 6;
        if (more && v != 0.0 && P + 1 > ndig) {
            int cap = P + 2 > DTOA_MAX ? DTOA_MAX : P + 2;
            ndig = dtoa_exact(v, d, &E, cap, &more);
        }
        dec_round(d, &ndig, &E, P, more);
        if (ndig == 0) {
            if (E < -4 || E >= P)
                fmt_sci(o, "0", 1, 0, sign, flags, width, 0, flags & F_ALT, upper);
            else
                fmt_fixed(o, d, 0, 0, sign, flags, width, 0, flags & F_ALT);
            return;
        }
        if (E < -4 || E >= P) {
            int p = P - 1;
            if (!(flags & F_ALT))
                while (p > 0 && (p >= ndig || d[p] == '0')) p--;
            fmt_sci(o, d, ndig, E, sign, flags, width, p, flags & F_ALT, upper);
        } else {
            int frac = P - 1 - E;
            if (!(flags & F_ALT))
                while (frac > 0 && (E + frac >= ndig || d[E + frac] == '0')) frac--;
            fmt_fixed(o, d, ndig, E, sign, flags, width, frac, flags & F_ALT);
        }
    }
}

/*------------------------------------------------------------------------------
 * The format engine
 *----------------------------------------------------------------------------*/
static i64 get_signed(va_list *ap, int len) {
    switch (len) {
    case LEN_HH: return (signed char)va_arg(*ap, int);
    case LEN_H:  return (short)va_arg(*ap, int);
    case LEN_L:  return va_arg(*ap, long);
    case LEN_LL: return va_arg(*ap, long long);
    case LEN_Z:  return (i64)va_arg(*ap, size_t);
    case LEN_J:  return va_arg(*ap, intmax_t);
    case LEN_T:  return (i64)va_arg(*ap, ptrdiff_t);
    default:     return va_arg(*ap, int);
    }
}

static u64 get_unsigned(va_list *ap, int len) {
    switch (len) {
    case LEN_HH: return (unsigned char)va_arg(*ap, unsigned);
    case LEN_H:  return (unsigned short)va_arg(*ap, unsigned);
    case LEN_L:  return va_arg(*ap, unsigned long);
    case LEN_LL: return va_arg(*ap, unsigned long long);
    case LEN_Z:  return va_arg(*ap, size_t);
    case LEN_J:  return va_arg(*ap, uintmax_t);
    case LEN_T:  return (u64)va_arg(*ap, ptrdiff_t);
    default:     return va_arg(*ap, unsigned);
    }
}

static int L_vformat(out_t *o, const char *fmt, va_list ap) {
    va_list a;
    va_copy(a, ap);

    for (; *fmt; fmt++) {
        unsigned flags = 0;
        int width = 0, prec = 0, has_prec = 0, len = LEN_INT;
        char conv;

        if (*fmt != '%') { o_putc(o, *fmt); continue; }
        fmt++;

        for (;;) {
            if (*fmt == '-') flags |= F_LEFT;
            else if (*fmt == '+') flags |= F_PLUS;
            else if (*fmt == ' ') flags |= F_SPACE;
            else if (*fmt == '#') flags |= F_ALT;
            else if (*fmt == '0') flags |= F_ZERO;
            else break;
            fmt++;
        }
        if (*fmt == '*') {
            int w = va_arg(a, int);
            if (w < 0) { flags |= F_LEFT; w = -w; }
            width = w;
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9') {
                width = width * 10 + (*fmt - '0');
                if (width > 0x3fffffff) width = 0x3fffffff;
                fmt++;
            }
        }
        if (*fmt == '.') {
            fmt++;
            has_prec = 1;
            if (*fmt == '*') {
                int p = va_arg(a, int);
                if (p < 0) has_prec = 0;
                else prec = p;
                fmt++;
            } else {
                prec = 0;
                while (*fmt >= '0' && *fmt <= '9') {
                    prec = prec * 10 + (*fmt - '0');
                    if (prec > 0x3fffffff) prec = 0x3fffffff;
                    fmt++;
                }
            }
        }
        switch (*fmt) {
        case 'h': fmt++; if (*fmt == 'h') { len = LEN_HH; fmt++; } else len = LEN_H; break;
        case 'l': fmt++; if (*fmt == 'l') { len = LEN_LL; fmt++; } else len = LEN_L; break;
        case 'z': len = LEN_Z; fmt++; break;
        case 'j': len = LEN_J; fmt++; break;
        case 't': len = LEN_T; fmt++; break;
        case 'L': len = LEN_CAP_L; fmt++; break;
        default: break;
        }

        conv = *fmt;
        if (conv == 0) { o_putc(o, '%'); break; }

        switch (conv) {
        case '%':
            o_putc(o, '%');
            break;
        case 'c':
            if (len == LEN_L) { (void)va_arg(a, int); o_putc(o, '?'); }
            else fmt_char(o, va_arg(a, int), flags, width);
            break;
        case 's':
            fmt_str(o, va_arg(a, const char *), flags, width, prec, has_prec);
            break;
        case 'd': case 'i': {
            i64 sv = get_signed(&a, len);
            u64 mag = sv < 0 ? (u64)(-(sv + 1)) + 1 : (u64)sv;
            fmt_int(o, mag, 10, 0, sv < 0, flags, width, prec, has_prec);
            break;
        }
        case 'u': case 'o': case 'x': case 'X': {
            u64 uv = get_unsigned(&a, len);
            unsigned base = conv == 'o' ? 8 : (conv == 'u' ? 10 : 16);
            fmt_int(o, uv, base, conv == 'X', 0, flags, width, prec, has_prec);
            break;
        }
        case 'p': {
            void *pv = va_arg(a, void *);
            if (!pv) fmt_str(o, "(nil)", flags, width, 0, 0);
            else fmt_int(o, (u64)(uintptr_t)pv, 16, 0, 0,
                         (flags & ~(F_PLUS | F_SPACE)) | F_ALT, width, prec,
                         has_prec);
            break;
        }
        case 'n':
            switch (len) {
            case LEN_HH: *va_arg(a, signed char *) = (signed char)o->count; break;
            case LEN_H:  *va_arg(a, short *) = (short)o->count; break;
            case LEN_L:  *va_arg(a, long *) = (long)o->count; break;
            case LEN_LL: *va_arg(a, long long *) = (long long)o->count; break;
            case LEN_Z:  *va_arg(a, size_t *) = o->count; break;
            case LEN_J:  *va_arg(a, intmax_t *) = (intmax_t)o->count; break;
            case LEN_T:  *va_arg(a, ptrdiff_t *) = (ptrdiff_t)o->count; break;
            default:     *va_arg(a, int *) = (int)o->count; break;
            }
            break;
        case 'f': case 'F': case 'e': case 'E':
        case 'g': case 'G': case 'a': case 'A': {
            double dv = (len == LEN_CAP_L) ? (double)va_arg(a, asm_ldouble)
                                           : va_arg(a, double);
            fmt_float(o, dv, conv, flags, width, prec, has_prec);
            break;
        }
        default:
            o_putc(o, '%');
            o_putc(o, conv);
            break;
        }
    }
    va_end(a);
    return (int)o->count;
}

/*------------------------------------------------------------------------------
 * Buffer sink and the public entry points
 *----------------------------------------------------------------------------*/
struct buffer {
    char *dst;
    size_t cap;
    size_t used;
};

static void buffer_emit(void *ctx, const char *s, size_t n) {
    struct buffer *b = ctx;
    size_t room = b->cap ? b->cap - 1 : 0;
    if (b->used < room) {
        size_t avail = room - b->used;
        size_t k = n < avail ? n : avail;
        s_copy(b->dst + b->used, s, k);
        b->used += k;
    }
}

int ASM_LIBC(vsnprintf)(char *dst, size_t size, const char *fmt, va_list ap) {
    struct buffer b;
    out_t o;
    int r;
    b.dst = dst;
    b.cap = size;
    b.used = 0;
    o.emit = buffer_emit;
    o.ctx = &b;
    o.count = 0;
    r = L_vformat(&o, fmt, ap);
    if (size) dst[b.used < (size - 1) ? b.used : (size - 1)] = 0;
    return r;
}

int ASM_LIBC(snprintf)(char *dst, size_t size, const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = ASM_LIBC(vsnprintf)(dst, size, fmt, ap);
    va_end(ap);
    return r;
}

int ASM_LIBC(vsprintf)(char *dst, const char *fmt, va_list ap) {
    return ASM_LIBC(vsnprintf)(dst, (size_t)-1, fmt, ap);
}

int ASM_LIBC(sprintf)(char *dst, const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = ASM_LIBC(vsnprintf)(dst, (size_t)-1, fmt, ap);
    va_end(ap);
    return r;
}

struct abuf {
    char *buf;
    size_t len, cap;
    int err;
};

static void abuf_emit(void *ctx, const char *s, size_t n) {
    struct abuf *b = ctx;
    if (b->err) return;
    if (b->len + n + 1 > b->cap) {
        size_t nc = b->cap ? b->cap : 64;
        char *p;
        while (nc < b->len + n + 1) nc <<= 1;
        p = (char *)ASM_LIBC(realloc)(b->buf, nc);
        if (!p) { b->err = 1; return; }
        b->buf = p;
        b->cap = nc;
    }
    s_copy(b->buf + b->len, s, n);
    b->len += n;
}

int ASM_LIBC(vasprintf)(char **strp, const char *fmt, va_list ap) {
    struct abuf b;
    out_t o;
    int r;
    b.buf = NULL; b.len = 0; b.cap = 0; b.err = 0;
    o.emit = abuf_emit;
    o.ctx = &b;
    o.count = 0;
    r = L_vformat(&o, fmt, ap);
    if (b.err) {
        ASM_LIBC(free)(b.buf);
        *strp = NULL;
        return -1;
    }
    if (!b.buf) {
        b.buf = (char *)ASM_LIBC(malloc)(1);
        if (!b.buf) { *strp = NULL; return -1; }
    }
    b.buf[b.len] = 0;
    *strp = b.buf;
    return r;
}

int ASM_LIBC(asprintf)(char **strp, const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = ASM_LIBC(vasprintf)(strp, fmt, ap);
    va_end(ap);
    return r;
}
