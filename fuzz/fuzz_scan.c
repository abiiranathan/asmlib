/*==============================================================================
 * fuzz_scan.c - libFuzzer target for asm_sscanf
 *------------------------------------------------------------------------------
 * Bytes drive a source string and a supported format
 * (%[width][ll]<d|i|u|x|X|o|c|s>, at most 8 conversions). The assembly
 * backends are checked against two oracles: the project's portable C backend
 * (asm_ref_sscanf) and, when it conforms, the host sscanf. glibc before 2.42
 * accepts inputs (a short %c field, a lone 0x prefix) that ISO C requires to
 * fail, so the host is only consulted when a one-time probe shows it agrees
 * with the standard. All three receive eight 16-byte destination slots; the
 * return value and every slot byte must match. %s always carries a small width
 * so the slots cannot be overrun.
 *============================================================================*/

#include "asmlib.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

int asm_ref_sscanf(const char *src, const char *fmt, ...);

/* glibc < 2.42 reads a short %c field successfully and treats a lone 0x hex
 * prefix as a successful zero conversion; ISO C requires a matching failure. */
static int host_conforms(void) {
    static int cached = -1;
    if (cached < 0) {
        char b[4];
        unsigned v = 0;
        cached = sscanf("a", "%3c", b) == -1 && sscanf("0x", "%x", &v) == 0;
    }
    return cached;
}

static unsigned nextb(const uint8_t *d, size_t n, size_t *i) {
    return *i < n ? d[(*i)++] : 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < 16) return 0;

    size_t slen = n / 2;
    if (slen > 400) slen = 400;
    char src[512];
    memcpy(src, d, slen);
    src[slen] = 0;

    size_t i = slen;
    char fmt[200];
    size_t fl = 0;
    int conv = 0;
    while (i < n && fl < 180) {
        uint8_t c = nextb(d, n, &i);
        if (c >= 128 && conv < 8) {
            static const char specs[] = "diuxXocs";
            char spec = specs[c % 8];
            unsigned wd = nextb(d, n, &i) % 8;
            if (spec == 's' && wd == 0) wd = 1;
            fmt[fl++] = '%';
            if (wd) fmt[fl++] = (char)('0' + wd);
            if ((c & 0x40) && spec != 'c' && spec != 's') { fmt[fl++] = 'l'; fmt[fl++] = 'l'; }
            fmt[fl++] = spec;
            conv++;
        } else {
            char lit = (char)(' ' + (c % 95));
            if (lit == '%') lit = '!';
            fmt[fl++] = lit;
        }
    }
    fmt[fl] = 0;

    unsigned char sb[8][16], sr[8][16];
    memset(sb, 0x5A, sizeof sb);
    memset(sr, 0x5A, sizeof sr);
    int rb = asm_sscanf(src, fmt, sb[0], sb[1], sb[2], sb[3], sb[4], sb[5], sb[6], sb[7]);
    int rr = asm_ref_sscanf(src, fmt, sr[0], sr[1], sr[2], sr[3], sr[4], sr[5], sr[6], sr[7]);
    if (rb != rr) __builtin_trap();
    if (memcmp(sb, sr, sizeof sb) != 0) __builtin_trap();

    if (host_conforms()) {
        unsigned char sa[8][16];
        memset(sa, 0x5A, sizeof sa);
        int ra = sscanf(src, fmt, sa[0], sa[1], sa[2], sa[3], sa[4], sa[5], sa[6], sa[7]);
        if (ra != rb) __builtin_trap();
        if (memcmp(sa, sb, sizeof sa) != 0) __builtin_trap();
    }
    return 0;
}
