/*==============================================================================
 * test_format.c - differential tests for the asmlib formatting helpers
 *------------------------------------------------------------------------------
 * Every supported asm_snprintf conversion is compared byte-for-byte (and by
 * return value) against the host snprintf across values, flags, widths, length
 * modifiers and buffer sizes, including truncated and zero-size buffers. The
 * integer formatters are checked against snprintf and against a hand-written
 * reference, and a guard-page section proves they never write past `cap`.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <unistd.h>

#include "asmlib.h"

static unsigned long checks = 0;
static unsigned long failures = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        checks++;                                                            \
        if (!(cond)) {                                                       \
            printf("FAIL: %-22s line %-4d (%s)\n", (msg), __LINE__, #cond);  \
            failures++;                                                      \
        }                                                                    \
    } while (0)

/*------------------------------------------------------------------------------
 * asm_snprintf vs. the host snprintf
 *------------------------------------------------------------------------------
 * Both buffers start filled with 0xAA; the whole array is compared afterwards,
 * so a stray write past the terminator is caught as well.
 *----------------------------------------------------------------------------*/
#define DIFF(size, ...)                                                      \
    do {                                                                     \
        char a_[192], b_[192];                                               \
        memset(a_, 0xAA, sizeof a_);                                         \
        memset(b_, 0xAA, sizeof b_);                                         \
        int ra_ = snprintf(a_, (size), __VA_ARGS__);                         \
        int rb_ = asm_snprintf(b_, (size), __VA_ARGS__);                     \
        checks++;                                                            \
        if (ra_ != rb_ || memcmp(a_, b_, sizeof a_) != 0) {                  \
            printf("FAIL: snprintf line %-4d size=%zu ret %d/%d\n",          \
                   __LINE__, (size_t)(size), ra_, rb_);                      \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static void test_snprintf_literals(void) {
    DIFF(64, "hello");
    DIFF(64, "");
    DIFF(64, "a%%b");
    DIFF(64, "100%% done");
    DIFF(64, "%%");
    for (size_t n = 0; n <= 14; n++) DIFF(n, "hello world");
    for (size_t n = 0; n <= 6; n++) DIFF(n, "%%");
}

static void test_snprintf_ints(void) {
    static const long long vals[] = {
        0, 1, -1, 7, -7, 42, -42, 255, -255, 256, 1000, -1000,
        32767, -32768, 65535, 2147483647LL, -2147483648LL,
        9223372036854775807LL, -9223372036854775807LL - 1,
        123456789012345LL, -98765432109LL,
    };
    static const char *fmts[] = {
        "%d", "%i", "%5d", "%-5d", "%05d", "%-05d", "%8d", "%08d",
        "%u", "%5u", "%-5u", "%05u", "%x", "%X", "%5x", "%-5x", "%05x",
        "%ld", "%lld", "%lu", "%llu", "%lx", "%llX", "%5lld", "%-8llu",
        "%08llx", "%llu", "%llx",
    };
    const size_t nfmt = sizeof fmts / sizeof fmts[0];

    for (size_t v = 0; v < sizeof vals / sizeof vals[0]; v++) {
        for (size_t f = 0; f < nfmt; f++) {
            const char *fmt = fmts[f];
            int is64 = strstr(fmt, "ll") != NULL || strstr(fmt, "l") != NULL;
            if (is64) {
                if (strchr(fmt, 'd') || strchr(fmt, 'i'))
                    DIFF(64, fmt, vals[v]);
                else
                    DIFF(64, fmt, (unsigned long long)vals[v]);
            } else {
                if (strchr(fmt, 'd') || strchr(fmt, 'i'))
                    DIFF(64, fmt, (int)vals[v]);
                else
                    DIFF(64, fmt, (unsigned)vals[v]);
            }
        }
    }
    /* octals separately (keep the array above readable) */
    static const unsigned long long octs[] = {0, 1, 7, 8, 63, 64, 0777, 0xffffffffULL, ~0ULL};
    for (size_t v = 0; v < sizeof octs / sizeof octs[0]; v++) {
        DIFF(64, "%o", (unsigned)octs[v]);
        DIFF(64, "%llo", octs[v]);
        DIFF(64, "%10llo", octs[v]);
        DIFF(64, "%-10llo", octs[v]);
        DIFF(64, "%010llo", octs[v]);
    }
}

static void test_snprintf_widths(void) {
    for (int w = 0; w <= 12; w++) {
        char f[16];
        snprintf(f, sizeof f, "%%%dd", w);   DIFF(64, f, -7);
        snprintf(f, sizeof f, "%%-%dd", w);  DIFF(64, f, -7);
        snprintf(f, sizeof f, "%%0%dd", w);  DIFF(64, f, -7);
        snprintf(f, sizeof f, "%%%dx", w);   DIFF(64, f, 0xabc);
        snprintf(f, sizeof f, "%%0%dX", w);  DIFF(64, f, 0xabc);
        snprintf(f, sizeof f, "%%%ds", w);   DIFF(64, f, "abc");
        snprintf(f, sizeof f, "%%-%ds", w);  DIFF(64, f, "abc");
        snprintf(f, sizeof f, "%%%dc", w);   DIFF(64, f, 'Z');
        snprintf(f, sizeof f, "%%%du", w);   DIFF(64, f, 12u);
    }
}

static void test_snprintf_strings(void) {
    DIFF(64, "[%s]", "hello");
    DIFF(64, "[%s]", "");
    DIFF(64, "%s", (char *)NULL);
    DIFF(64, "[%10s]", "hi");
    DIFF(64, "[%-10s]", "hi");
    DIFF(64, "[%010s]", "hi");
    DIFF(64, "[%2s]", "hello");
    DIFF(64, "%c%c%c", 'a', 'b', 'c');
    DIFF(64, "[%5c]", 'x');
    DIFF(64, "[%-5c]", 'x');
    DIFF(64, "[%05c]", 'x');
    DIFF(6, "%s%s", "abc", "def");
    for (size_t n = 0; n <= 8; n++) DIFF(n, "[%s]", "abcdef");
}

static void test_snprintf_pointer(void) {
    int x = 0;
    DIFF(64, "%p", (void *)NULL);
    DIFF(64, "%p", (void *)&x);
    DIFF(64, "%p", (void *)0x1234);
    DIFF(64, "%18p", (void *)0x1234);
    DIFF(64, "%-18p", (void *)0x1234);
    DIFF(64, "%p", (void *)0xdeadbeefcafeULL);
}

static void test_snprintf_unsupported(void) {
    /* Genuinely unknown conversions are copied literally, no argument. */
    char b[64];
    int r = asm_snprintf(b, sizeof b, "%q");
    CHECK(r == 2 && strcmp(b, "%q") == 0, "unknown passthrough");
    r = asm_snprintf(b, sizeof b, "a%yb");
    CHECK(r == 4 && strcmp(b, "a%yb") == 0, "unknown passthrough 2");
}

/* Floating point: every supported conversion is compared byte-for-byte against
 * the host snprintf, over a table of special/awkward values and random bit
 * patterns. */
static int f_is_special(double v) {
    union { double d; uint64_t u; } x;
    x.d = v;
    return ((x.u >> 52) & 0x7ff) == 0x7ff;
}

static uint64_t f_rng = 0x243F6A8885A308D3ULL;
static double f_rnd(void) {
    union { uint64_t u; double d; } x;
    f_rng ^= f_rng << 13; f_rng ^= f_rng >> 7; f_rng ^= f_rng << 17;
    x.u = (f_rng << 1) | (f_rng & 1);
    return x.d;
}

static void test_snprintf_floats(void) {
    static const double vals[] = {
        0.0, -0.0, 1.0, -1.0, 0.5, 1.5, 3.14159265358979, -2.718281828459045,
        123456.789, 1e-7, 1e7, 1e-300, 1e300, 0.0001234, 999999.5,
        0.1, 0.2, 0.3, 2.0 / 3.0, 1e20, -1e20, 5e-324,
        1.7976931348623157e308, 2.2250738585072014e-308, 100.0, 1234.5678,
        1.0 / 7.0, 6.02214076e23, 0.0001, 0.00001,
    };
    static const char *fmts[] = {
        "%f", "%F", "%.0f", "%.1f", "%.2f", "%.10f", "%12.3f", "%-12.3f",
        "%012.3f", "%+.2f", "% .2f", "%#.0f", "%e", "%E", "%.0e", "%.3e",
        "%.10e", "%12.3e", "%-12.3e", "%012.3e", "%g", "%G", "%.0g", "%.3g",
        "%.10g", "%12.5g", "%-12.5g", "%#.5g", "%a", "%A", "%.0a", "%.3a", "%#.0a",
    };
    const size_t nv = sizeof vals / sizeof vals[0];
    const size_t nf = sizeof fmts / sizeof fmts[0];
    for (size_t v = 0; v < nv; v++)
        for (size_t f = 0; f < nf; f++) DIFF(192, fmts[f], vals[v]);

    for (int i = 0; i < 5000; i++) {
        double v = f_rnd();
        if (f_is_special(v)) continue;
        DIFF(192, "%.17g", v);
        DIFF(192, "%.6f", v);
        DIFF(192, "%.9e", v);
        DIFF(192, "%a", v);
    }
}

/*------------------------------------------------------------------------------
 * Integer formatter reference and differential checks
 *----------------------------------------------------------------------------*/
static const char digits_lc[] = "0123456789abcdefghijklmnopqrstuvwxyz";

static size_t ref_u64toa(uint64_t v, char *buf, unsigned base) {
    char tmp[72];
    size_t n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = digits_lc[v % base]; v /= base; }
    size_t i;
    for (i = 0; i < n; i++) buf[i] = tmp[n - 1 - i];
    buf[n] = 0;
    return n;
}

static void test_u64toa(void) {
    static const uint64_t vals[] = {
        0, 1, 9, 10, 99, 100, 12345, 999999999, 1000000000,
        18446744073709551615ULL, 12345678901234567890ULL,
    };
    for (size_t i = 0; i < sizeof vals / sizeof vals[0]; i++) {
        char a[80], b[80];
        size_t r = asm_u64toa(vals[i], b, sizeof b);
        int h = snprintf(a, sizeof a, "%llu", (unsigned long long)vals[i]);
        CHECK(r == (size_t)h && strcmp(a, b) == 0, "u64toa decimal");
    }
    /* base variants against the reference */
    for (unsigned base = 2; base <= 36; base++) {
        for (size_t i = 0; i < sizeof vals / sizeof vals[0]; i++) {
            char b[80], c[80];
            size_t r = asm_u64toa_base(vals[i], b, sizeof b, base);
            size_t rr = ref_u64toa(vals[i], c, base);
            CHECK(r == rr && strcmp(b, c) == 0, "u64toa_base");
        }
    }
    /* hex, both cases */
    for (size_t i = 0; i < sizeof vals / sizeof vals[0]; i++) {
        char a[80], b[80];
        asm_u64tohex(vals[i], b, sizeof b, 0);
        snprintf(a, sizeof a, "%llx", (unsigned long long)vals[i]);
        CHECK(strcmp(a, b) == 0, "u64tohex lower");
        asm_u64tohex(vals[i], b, sizeof b, 1);
        snprintf(a, sizeof a, "%llX", (unsigned long long)vals[i]);
        CHECK(strcmp(a, b) == 0, "u64tohex upper");
    }
    /* randomised decimal, to exercise the reciprocal-multiply magic */
    uint64_t seed = 0x9E3779B97F4A7C15ULL;
    for (int i = 0; i < 50000; i++) {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
        char a[64], b[64];
        size_t r = asm_u64toa(seed, b, sizeof b);
        int h = snprintf(a, sizeof a, "%llu", (unsigned long long)seed);
        CHECK(r == (size_t)h && strcmp(a, b) == 0, "u64toa random");
        char a2[64], b2[64];
        r = asm_i64toa((int64_t)seed, b2, sizeof b2);
        h = snprintf(a2, sizeof a2, "%lld", (long long)seed);
        CHECK(r == (size_t)h && strcmp(a2, b2) == 0, "i64toa random");
        char a3[64], b3[64];
        asm_u64tohex(seed, b3, sizeof b3, 0);
        snprintf(a3, sizeof a3, "%llx", (unsigned long long)seed);
        CHECK(strcmp(a3, b3) == 0, "u64tohex random");
    }
    /* bad base writes an empty string and returns 0 */
    { char b[8] = "xxxx"; CHECK(asm_u64toa_base(5, b, sizeof b, 1) == 0 && b[0] == 0, "bad base 1");
      CHECK(asm_u64toa_base(5, b, sizeof b, 37) == 0 && b[0] == 0, "bad base 37"); }
}

static void test_i64toa(void) {
    static const int64_t vals[] = {
        0, 1, -1, 42, -42, 2147483647LL, -2147483648LL,
        9223372036854775807LL, -9223372036854775807LL - 1,
    };
    for (size_t i = 0; i < sizeof vals / sizeof vals[0]; i++) {
        char a[80], b[80];
        size_t r = asm_i64toa(vals[i], b, sizeof b);
        int h = snprintf(a, sizeof a, "%lld", (long long)vals[i]);
        CHECK(r == (size_t)h && strcmp(a, b) == 0, "i64toa");
    }
}

/* Truncation: the return value is the full length; the buffer holds the
 * leading characters plus a NUL, and never more than cap bytes change. */
static void test_truncation(void) {
    static const uint64_t vals[] = { 0, 5, 42, 1000, 18446744073709551615ULL };
    for (size_t i = 0; i < sizeof vals / sizeof vals[0]; i++) {
        char full[80];
        size_t full_len = asm_u64toa(vals[i], full, sizeof full);
        for (size_t cap = 0; cap <= full_len + 2; cap++) {
            char buf[80];
            memset(buf, 0xAA, sizeof buf);
            size_t r = asm_u64toa(vals[i], buf, cap);
            CHECK(r == full_len, "trunc return");
            size_t expect = cap ? cap - 1 : 0;
            if (expect > full_len) expect = full_len;
            CHECK(memcmp(buf, full, expect) == 0, "trunc prefix");
            if (cap) CHECK(buf[expect] == 0, "trunc NUL");
            if (cap) CHECK((unsigned char)buf[cap] == 0xAA, "trunc no overrun");
        }
    }
}

/*------------------------------------------------------------------------------
 * Guard-page section: no write may touch the PROT_NONE page after the buffer
 *----------------------------------------------------------------------------*/
static sigjmp_buf g_jmp;
static volatile int g_fault;
static void on_segv(int sig) { (void)sig; g_fault = 1; siglongjmp(g_jmp, 1); }

static void test_guard(void) {
    long pg = sysconf(_SC_PAGESIZE);
    unsigned char *base = mmap(NULL, (size_t)pg * 2, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) { CHECK(0, "guard mmap"); return; }
    if (mprotect(base + pg, (size_t)pg, PROT_NONE) != 0) { CHECK(0, "guard mprotect"); return; }

    struct sigaction sa, old;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_segv;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old);

    /* place buf so that buf + cap == guard page for every cap we try */
    for (size_t cap = 1; cap <= 40; cap++) {
        unsigned char *buf = base + pg - cap;
        g_fault = 0;
        if (sigsetjmp(g_jmp, 1) == 0) {
            asm_u64toa(18446744073709551615ULL, (char *)buf, cap);
            asm_i64toa((int64_t)-9223372036854775807LL - 1, (char *)buf, cap);
            asm_u64tohex(0xdeadbeefcafeULL, (char *)buf, cap, 1);
            asm_snprintf((char *)buf, cap, "%08llx|%s|%-10d", 0xabcULL, "xy", -5);
        } else {
            CHECK(0, "guard page write");
        }
    }
    /* cap == 0 must write nothing at all (buf sits right on the guard page) */
    g_fault = 0;
    if (sigsetjmp(g_jmp, 1) == 0) {
        asm_u64toa(123, (char *)(base + pg), 0);
        asm_snprintf((char *)(base + pg), 0, "%d", 123);
    } else {
        CHECK(0, "cap 0 wrote");
    }
    sigaction(SIGSEGV, &old, NULL);
    munmap(base, (size_t)pg * 2);
}

#if ASMLIB_OS_HEAP
static void test_dprintf(void) {
    char tmpl[] = "/tmp/asmlib_dprintf_XXXXXX";
    char expect[128], got[160];
    int fd = mkstemp(tmpl);
    int r, re, n;
    if (fd < 0) { CHECK(0, "dprintf mkstemp"); return; }
    r = asm_dprintf(fd, "n=%d s=%s f=%.3f\n", -7, "hi", 3.14159);
    re = snprintf(expect, sizeof expect, "n=%d s=%s f=%.3f\n", -7, "hi", 3.14159);
    lseek(fd, 0, SEEK_SET);
    n = (int)read(fd, got, sizeof got);
    CHECK(r == re && n == re && memcmp(got, expect, (size_t)re) == 0, "dprintf");
    close(fd);
    unlink(tmpl);
}
#endif

int main(void) {
    printf("== asmlib format test suite ==\n");
    test_snprintf_literals();   printf("   literals    done\n");
    test_snprintf_ints();       printf("   ints        done\n");
    test_snprintf_widths();     printf("   widths      done\n");
    test_snprintf_strings();    printf("   strings     done\n");
    test_snprintf_pointer();    printf("   pointer     done\n");
    test_snprintf_unsupported();printf("   unknown     done\n");
    test_snprintf_floats();     printf("   floats      done\n");
    test_u64toa();              printf("   u64toa      done\n");
    test_i64toa();              printf("   i64toa      done\n");
    test_truncation();          printf("   truncation  done\n");
    test_guard();               printf("   guard       done\n");
#if ASMLIB_OS_HEAP
    test_dprintf();             printf("   dprintf     done\n");
#endif
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
