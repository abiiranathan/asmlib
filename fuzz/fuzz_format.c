/*==============================================================================
 * fuzz_format.c - libFuzzer target for asm_snprintf
 *------------------------------------------------------------------------------
 * The bytes drive a generator that emits a supported format (literals and
 * %[flags][width][ll]<d|i|u|x|X|o>, at most 8 conversions) and eight 64-bit
 * arguments. asm_snprintf and the host snprintf must agree on the return value
 * and the whole buffer, byte for byte. Because both read a 64-bit vararg slot
 * and truncate identically for the width-less conversions, the same argument
 * list is valid for both.
 *============================================================================*/

#include "asmlib.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned nextb(const uint8_t *d, size_t n, size_t *i) {
    return *i < n ? d[(*i)++] : 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < 16) return 0;

    unsigned long long vals[8];
    size_t i = 0;
    for (int k = 0; k < 8; k++) {
        unsigned long long v = 0;
        for (int b = 0; b < 8; b++) v = (v << 8) | nextb(d, n, &i);
        vals[k] = v;
    }

    char fmt[200];
    size_t fl = 0;
    int conv = 0;
    while (i < n && fl < 180) {
        uint8_t c = nextb(d, n, &i);
        if (c >= 128 && conv < 8) {
            static const char specs[] = "diuxXo";
            uint8_t flags = nextb(d, n, &i);
            unsigned wd = nextb(d, n, &i) % 12;
            fmt[fl++] = '%';
            if (flags & 1) fmt[fl++] = '-';
            else if (flags & 2) fmt[fl++] = '0';
            if (wd >= 10) { fmt[fl++] = '1'; fmt[fl++] = (char)('0' + wd - 10); }
            else if (wd) fmt[fl++] = (char)('0' + wd);
            if (flags & 4) { fmt[fl++] = 'l'; fmt[fl++] = 'l'; }
            fmt[fl++] = specs[c % 5];
            conv++;
        } else {
            char lit = (char)(' ' + (c % 95));
            if (lit == '%') lit = '!';
            fmt[fl++] = lit;
        }
    }
    fmt[fl] = 0;

    char a[512], b[512];
    memset(a, 0x5A, sizeof a);
    memset(b, 0x5A, sizeof b);
    int ra = snprintf(a, sizeof a, fmt, vals[0], vals[1], vals[2], vals[3],
                      vals[4], vals[5], vals[6], vals[7]);
    int rb = asm_snprintf(b, sizeof b, fmt, vals[0], vals[1], vals[2], vals[3],
                          vals[4], vals[5], vals[6], vals[7]);
    if (ra != rb) __builtin_trap();
    if (memcmp(a, b, sizeof a) != 0) __builtin_trap();
    return 0;
}
