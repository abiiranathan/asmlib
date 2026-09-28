/*==============================================================================
 * test_scan.c - differential and safety tests for asm_sscanf
 *------------------------------------------------------------------------------
 * Every supported conversion is compared with the host sscanf on the same
 * input: return value and assigned value must match. Safety is checked with
 * guard pages: the scanner must never read past the source NUL and %s/%c must
 * never write past the declared width.
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

static void report(const char *kind, const char *src, const char *fmt,
                   int ra, int rb, long long a, long long b) {
    printf("FAIL %s '%s' '%s': ret %d/%d val %lld/%lld\n",
           kind, src, fmt, ra, rb, a, b);
    failures++;
}

/*------------------------------------------------------------------------------
 * Per-type differential helpers
 *----------------------------------------------------------------------------*/
static void di32(const char *src, const char *fmt) {
    int a = 0x5a5a5a5a, b = 0x5a5a5a5a;
    int ra = sscanf(src, fmt, &a), rb = asm_sscanf(src, fmt, &b);
    checks++;
    if (ra != rb || a != b) report("i32", src, fmt, ra, rb, a, b);
}
static void di64(const char *src, const char *fmt) {
    long long a = 0x1111111111111111LL, b = 0x1111111111111111LL;
    int ra = sscanf(src, fmt, &a), rb = asm_sscanf(src, fmt, &b);
    checks++;
    if (ra != rb || a != b) report("i64", src, fmt, ra, rb, a, b);
}
static void du32(const char *src, const char *fmt) {
    unsigned a = 0x5a5a5a5au, b = 0x5a5a5a5au;
    int ra = sscanf(src, fmt, &a), rb = asm_sscanf(src, fmt, &b);
    checks++;
    if (ra != rb || a != b) report("u32", src, fmt, ra, rb, a, b);
}
static void du64(const char *src, const char *fmt) {
    unsigned long long a = 0x1111111111111111ULL, b = 0x1111111111111111ULL;
    int ra = sscanf(src, fmt, &a), rb = asm_sscanf(src, fmt, &b);
    checks++;
    if (ra != rb || a != b) report("u64", src, fmt, ra, rb, a, b);
}
static void dstr(const char *src, const char *fmt) {
    char a[96], b[96];
    memset(a, 0xAA, sizeof a);
    memset(b, 0xAA, sizeof b);
    int ra = sscanf(src, fmt, a), rb = asm_sscanf(src, fmt, b);
    checks++;
    if (ra != rb || memcmp(a, b, sizeof a) != 0) {
        printf("FAIL str '%s' '%s': ret %d/%d '%s'/'%s'\n", src, fmt, ra, rb, a, b);
        failures++;
    }
}
static void dchar(const char *src, const char *fmt, int n) {
    char a[32], b[32];
    memset(a, 0xAA, sizeof a);
    memset(b, 0xAA, sizeof b);
    int ra = sscanf(src, fmt, a), rb = asm_sscanf(src, fmt, b);
    checks++;
    if (ra != rb || memcmp(a, b, (size_t)n) != 0) {
        printf("FAIL char '%s' '%s': ret %d/%d\n", src, fmt, ra, rb);
        failures++;
    }
}

static void test_ints(void) {
    static const char *srcs[] = {
        "42", "  42", "42abc", "-7", "+7", "0", "00", "007", "0x1f", "0X1F",
        "-0x10", "", "   ", "abc", "12 34", "2147483647", "-2147483648",
        "2147483648", "-2147483649", "4294967295", "4294967296",
        "999999999999999999999", "-999999999999999999999",
        "9223372036854775807", "-9223372036854775808", "18446744073709551615",
        "+", "-", "0x", "0xg", "1234567890", "0000000000000000000042",
    };
    static const char *sfmt[]  = { "%d", "%i", "%5d", "%*d%d", "%ld", "%lld" };
    static const char *ufmt[]  = { "%u", "%x", "%X", "%o", "%lu", "%llx", "%llo" };
    for (size_t s = 0; s < sizeof srcs / sizeof srcs[0]; s++) {
        for (size_t f = 0; f < sizeof sfmt / sizeof sfmt[0]; f++) {
            const char *fmt = sfmt[f];
            if (strchr(fmt, 'l')) di64(srcs[s], fmt); else di32(srcs[s], fmt);
        }
        for (size_t f = 0; f < sizeof ufmt / sizeof ufmt[0]; f++) {
            const char *fmt = ufmt[f];
            if (strstr(fmt, "l")) du64(srcs[s], fmt); else du32(srcs[s], fmt);
        }
    }
}

static void test_strings(void) {
    static const char *srcs[] = {
        "hello world", "  padded\ttext ", "", "   ", "a", "abcdefghijklmnop",
        "one\ttwo\nthree", "-123 x",
    };
    for (size_t s = 0; s < sizeof srcs / sizeof srcs[0]; s++) {
        dstr(srcs[s], "%31s");
        dstr(srcs[s], " %5s");
        dstr(srcs[s], "%1s");
        dchar(srcs[s], "%c", 1);
        dchar(srcs[s], "%3c", 1);
    }
    /* two destinations in one call */
    {
        char a1[32], b1[32];
        memset(a1, 0, sizeof a1); memset(b1, 0, sizeof b1);
        int ra = sscanf("foo bar", "%5s %5s", a1, b1);
        char c1[32], d1[32];
        memset(c1, 0, sizeof c1); memset(d1, 0, sizeof d1);
        int rb = asm_sscanf("foo bar", "%5s %5s", c1, d1);
        checks++;
        if (ra != rb || strcmp(a1, c1) || strcmp(b1, d1)) {
            printf("FAIL two-str ret %d/%d '%s'/'%s'\n", ra, rb, a1, c1); failures++;
        }
    }
    /* multi-argument mixed formats */
    {
        char a1[32], b1[32];
        int a2 = 0, b2 = 0; unsigned a3 = 0, b3 = 0;
        memset(a1, 0, sizeof a1); memset(b1, 0, sizeof b1);
        int ra = sscanf("id=42 name=zed hex=ff", "id=%d name=%15s hex=%x", &a2, a1, &a3);
        int rb = asm_sscanf("id=42 name=zed hex=ff", "id=%d name=%15s hex=%x", &b2, b1, &b3);
        checks++;
        if (ra != rb || a2 != b2 || a3 != b3 || strcmp(a1, b1)) {
            printf("FAIL mixed ret %d/%d\n", ra, rb); failures++;
        }
    }
    /* suppression: %*s then %s */
    dstr("skip keep", "%*s %15s");
    di32("10 20", "%*d %d");
}

static void test_percent_and_literals(void) {
    {
        int ia = 0, ib = 0;
        char ca = 0, cb = 0;
        int ra = sscanf("50%x", "%d%%%c", &ia, &ca);
        int rb = asm_sscanf("50%x", "%d%%%c", &ib, &cb);
        checks++;
        if (ra != rb || ia != ib || ca != cb) {
            printf("FAIL pct ret %d/%d %d/%d %c/%c\n", ra, rb, ia, ib, ca, cb);
            failures++;
        }
    }
    di32("  7", "  %d");
    di32("x7", "x%d");
    di32("a7", "b%d");           /* literal mismatch -> 0 */
    dstr("a b", "a %5s");
    /* unsupported conversion -> our format error */
    { int x = 0; int r = asm_sscanf("1.5", "%f", &x); CHECK(r == -1, "unsupported %f"); }
    /* %s without width -> format error */
    { char b[8]; int r = asm_sscanf("hello", "%s", b); CHECK(r == -1, "unbounded %s"); }
    /* %c without width is one char */
    dchar("Z", "%c", 1);
}

static void test_pointer(void) {
    void *a = (void *)0x1, *b = (void *)0x1;
    int ra = sscanf("0xdeadbeef", "%p", &a);
    int rb = asm_sscanf("0xdeadbeef", "%p", &b);
    checks++;
    if (ra != rb || a != b) { printf("FAIL ptr %d/%d %p/%p\n", ra, rb, a, b); failures++; }
}

/*------------------------------------------------------------------------------
 * Guard pages
 *----------------------------------------------------------------------------*/
static sigjmp_buf g_jmp;
static volatile int g_fault;
static void on_segv(int sig) { (void)sig; g_fault = 1; siglongjmp(g_jmp, 1); }

static void test_guards(void) {
    long pg = sysconf(_SC_PAGESIZE);
    struct sigaction sa, old;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_segv;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old);

    /* source read guard: NUL sits in the last valid byte before PROT_NONE */
    {
        unsigned char *base = mmap(NULL, (size_t)pg * 2, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        mprotect(base + pg, (size_t)pg, PROT_NONE);
        static const char *srcs[] = { "0", "123", "0x", "-", "9", " 1" };
        const char *fmts[] = { "%d", "%i", "%x", "%u", "%lld", "%5d" };
        for (size_t s = 0; s < sizeof srcs / sizeof srcs[0]; s++) {
            size_t n = strlen(srcs[s]);
            unsigned char *p = base + pg - n - 1;      /* NUL at pg-1 */
            memcpy(p, srcs[s], n + 1);
            for (size_t f = 0; f < sizeof fmts / sizeof fmts[0]; f++) {
                long long v = 0;                     /* holds any conversion */
                g_fault = 0;
                if (sigsetjmp(g_jmp, 1) == 0) asm_sscanf((char *)p, fmts[f], &v);
                else { CHECK(0, "source overread"); }
            }
        }
        munmap(base, (size_t)pg * 2);
    }
    /* destination write guard: %Ns writes exactly width+1 bytes at most */
    {
        unsigned char *base = mmap(NULL, (size_t)pg * 2, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        mprotect(base + pg, (size_t)pg, PROT_NONE);
        for (int w = 1; w <= 40; w++) {
            char fmt[16];
            snprintf(fmt, sizeof fmt, "%%%ds", w);
            unsigned char *buf = base + pg - (w + 1);   /* width+1 bytes */
            const char *src = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
            g_fault = 0;
            if (sigsetjmp(g_jmp, 1) == 0) {
                asm_sscanf(src, fmt, (char *)buf);
            } else { CHECK(0, "%s overrun"); }
        }
        for (int w = 1; w <= 32; w++) {
            char fmt[16];
            snprintf(fmt, sizeof fmt, "%%%dc", w);
            unsigned char *buf = base + pg - w;         /* exactly width bytes */
            const char *src = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
            g_fault = 0;
            if (sigsetjmp(g_jmp, 1) == 0) asm_sscanf(src, fmt, (char *)buf);
            else { CHECK(0, "%s overrun"); }
        }
        munmap(base, (size_t)pg * 2);
    }
    sigaction(SIGSEGV, &old, NULL);
}

int main(void) {
    printf("== asmlib scan test suite ==\n");
    test_ints();             printf("   ints      done\n");
    test_strings();          printf("   strings   done\n");
    test_percent_and_literals(); printf("   literals  done\n");
    test_pointer();          printf("   pointer   done\n");
    test_guards();           printf("   guards    done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
