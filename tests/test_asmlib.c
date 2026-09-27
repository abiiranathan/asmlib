/*==============================================================================
 * test_asmlib.c - differential and page-safety tests for the asmlib routines
 *------------------------------------------------------------------------------
 * Every vector routine is compared against its libc counterpart over a wide
 * range of sizes, offsets and contents. The page-boundary section places
 * buffers so that their final byte abuts a PROT_NONE guard page; a SIGSEGV is
 * caught and reported, proving the routines never read or write out of bounds.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <ctype.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <unistd.h>

#include "asmlib.h"

/* The truncation tests intentionally pass n smaller than the source length. */
#pragma GCC diagnostic ignored "-Wstringop-truncation"

/*------------------------------------------------------------------------------
 * Tiny test framework
 *----------------------------------------------------------------------------*/
static unsigned long checks = 0;
static unsigned long failures = 0;

#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        checks++;                                                            \
        if (!(cond)) {                                                       \
            printf("FAIL: %-24s line %-4d (%s)\n", (msg), __LINE__, #cond);  \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static int sgn(int x) { return (x > 0) - (x < 0); }

/* Deterministic xorshift PRNG so failures are reproducible. */
static uint64_t rng_state = 0x123456789abcdef0ULL;
static uint64_t rng(void) {
    uint64_t x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return rng_state = x;
}

/*------------------------------------------------------------------------------
 * Fault trapping: run an expression and report whether it touched a guard page.
 *----------------------------------------------------------------------------*/
static sigjmp_buf g_jmp;
static volatile sig_atomic_t g_faulted;

static void fault_handler(int sig) {
    (void)sig;
    g_faulted = 1;
    siglongjmp(g_jmp, 1);
}

/* Returns 1 if expr completed without faulting, 0 if it faulted. */
#define NO_FAULT(expr) \
    (g_faulted = 0, (sigsetjmp(g_jmp, 1) == 0) ? ((void)(expr), !g_faulted) : 0)

/*------------------------------------------------------------------------------
 * Memory primitives
 *----------------------------------------------------------------------------*/
static void test_memory(void) {
    enum { ARENA = 1024 };
    unsigned char *base = aligned_alloc(64, ARENA * 4);
    for (int b = 0; b < 4; b++)
        for (int i = 0; i < ARENA; i++)
            base[b * ARENA + i] = (unsigned char)rng();
    for (size_t n = 0; n <= 700; n++) {
        size_t aoff = rng() % 64;
        size_t boff = rng() % 64;
        unsigned char *src = base + 100 + aoff;
        unsigned char *d1  = base + ARENA + 100 + boff;
        unsigned char *d2  = base + 2 * ARENA + 100 + boff;
        /* memcpy */
        memcpy(d2, src, n);
        asm_memcpy(d1, src, n);
        CHECK(memcmp(d1, d2, n) == 0, "memcpy");
        /* memmove, disjoint and both overlap directions */
        for (long delta = -80; delta <= 80; delta += 7) {
            unsigned char work[1024], ref[1024];
            long msrc = 200, mdst = 200 + delta;
            if (mdst < 0 || mdst + (long)n > 1024) continue;
            for (int i = 0; i < 1024; i++) work[i] = ref[i] = (unsigned char)(i * 7 + 3);
            memmove(ref + mdst, ref + msrc, n);
            asm_memmove(work + mdst, work + msrc, n);
            CHECK(memcmp(work, ref, 1024) == 0, "memmove");
        }
        /* memset / bzero */
        memset(d2, 0x5A, ARENA);
        memset(d1, 0x5A, ARENA);
        int c = (int)(rng() & 0xFF);
        memset(d2 + 30, c, n);
        asm_memset(d1 + 30, c, n);
        CHECK(memcmp(d1, d2, ARENA) == 0, "memset");
        memset(d2 + 30, 0, n);
        asm_bzero(d1 + 30, n);
        CHECK(memcmp(d1, d2, ARENA) == 0, "bzero");
        /* memcmp */
        {
            unsigned char p[1200], q[1200];
            for (int i = 0; i < 1200; i++) p[i] = q[i] = (unsigned char)rng();
            int r1 = asm_memcmp(p, q, n), r2 = memcmp(p, q, n);
            CHECK(sgn(r1) == sgn(r2), "memcmp-eq");
            if (n) {
                size_t k = rng() % n;
                q[k] ^= 0xFF;
                r1 = asm_memcmp(p, q, n); r2 = memcmp(p, q, n);
                CHECK(sgn(r1) == sgn(r2), "memcmp-ne");
            }
        }
        /* memchr / memrchr */
        {
            unsigned char p[1200];
            for (int i = 0; i < 1200; i++) p[i] = (unsigned char)(rng() & 0x3F);
            for (int t = 0; t < 8; t++) {
                int ch = (int)(rng() & 0xFF);
                CHECK(asm_memchr(p, ch, n) == memchr(p, ch, n), "memchr");
                CHECK(asm_memrchr(p, ch, n) == memrchr(p, ch, n), "memrchr");
            }
        }
    }
    free(base);
}

/*------------------------------------------------------------------------------
 * Very large copies/fills - exercises the non-temporal-store paths
 *----------------------------------------------------------------------------*/
static void test_large(void) {
    size_t sizes[] = { (1u << 19) - 64, 1u << 19, (1u << 19) + 37,
                       1u << 20, (1u << 20) + 123, 3u << 20 };
    for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
        size_t n = sizes[s];
        unsigned char *a, *b, *c, *w, *r;
        if (posix_memalign((void **)&a, 64, n + 128) ||
            posix_memalign((void **)&b, 64, n + 128) ||
            posix_memalign((void **)&c, 64, n + 128) ||
            posix_memalign((void **)&w, 64, n + 8192) ||
            posix_memalign((void **)&r, 64, n + 8192)) {
            printf("large alloc failed\n"); failures++;
            continue;
        }
        for (size_t i = 0; i < n + 128; i++) a[i] = (unsigned char)(i * 31 + 7);
        for (size_t i = 0; i < n + 8192; i++) w[i] = r[i] = (unsigned char)(i * 13 + 5);

        /* memcpy: aligned (non-temporal path) and misaligned (fallback) */
        for (int mis = 0; mis < 64; mis += 13) {
            memset(b, 0, n + 128); memset(c, 0, n + 128);
            asm_memcpy(b + mis, a, n);
            memcpy(c + mis, a, n);
            CHECK(memcmp(b, c, n + 128) == 0, "large memcpy");
        }
        /* memset: aligned and misaligned */
        for (int mis = 0; mis < 64; mis += 17) {
            memset(b, 0x5A, n + 128); memset(c, 0x5A, n + 128);
            asm_memset(b + mis, 0x3C, n);
            memset(c + mis, 0x3C, n);
            CHECK(memcmp(b, c, n + 128) == 0, "large memset");
        }
        /* memmove overlapping with dst > src */
        asm_memmove(w + 4096, w, n - 4096);
        memmove(r + 4096, r, n - 4096);
        CHECK(memcmp(w, r, n) == 0, "large memmove");
        free(a); free(b); free(c); free(w); free(r);
    }
}

/*------------------------------------------------------------------------------
 * String primitives
 *----------------------------------------------------------------------------*/
static void test_string(void) {
    char s[512], d1[1024], d2[1024];
    /* Fully define the scratch pages so the SIMD over-read past a string's
     * NUL only touches initialised memory (keeps valgrind quiet). */
    memset(s, 0x7A, sizeof s);
    for (size_t len = 0; len < 260; len++) {
        for (size_t off = 0; off < 33 && off <= len; off++) {
            for (size_t i = 0; i < len; i++) s[i] = (char)(1 + (rng() % 120));
            s[len] = 0;
            CHECK(asm_strlen(s + off) == strlen(s + off), "strlen");
            for (size_t ml = 0; ml <= len + 3; ml += 1 + (ml / 8))
                CHECK(asm_strnlen(s + off, ml) == strnlen(s + off, ml), "strnlen");
            for (size_t n = 0; n <= len + 3 && n < 600; n++) {
                memset(d1, 0x7E, sizeof d1); memset(d2, 0x7E, sizeof d2);
                asm_strncpy(d1, s, n);
                strncpy(d2, s, n);
                CHECK(memcmp(d1, d2, 600) == 0, "strncpy");
            }
            /* strcat / strncat */
            for (size_t n = 0; n <= len + 3 && n < 300; n++) {
                memset(d1, 0x55, sizeof d1); memset(d2, 0x55, sizeof d2);
                strcpy(d1, "pre:"); strcpy(d2, "pre:");
                asm_strncat(d1, s, n);
                strncat(d2, s, n);
                CHECK(memcmp(d1, d2, 700) == 0, "strncat");
            }
        }
    }
}

/*------------------------------------------------------------------------------
 * Comparison
 *----------------------------------------------------------------------------*/
static void test_compare(void) {
    char a[96], b[96];
    memset(a, 'A', sizeof a);           /* define all bytes for valgrind */
    memset(b, 'B', sizeof b);
    for (int it = 0; it < 40000; it++) {
        int la = rng() % 60, lb = rng() % 60;
        for (int i = 0; i < la; i++) a[i] = (char)(1 + rng() % 40);
        for (int i = 0; i < lb; i++) b[i] = (char)(1 + rng() % 40);
        a[la] = 0; b[lb] = 0;
        CHECK(sgn(asm_strcmp(a, b)) == sgn(strcmp(a, b)), "strcmp");
        size_t n = rng() % 70;
        CHECK(sgn(asm_strncmp(a, b, n)) == sgn(strncmp(a, b, n)), "strncmp");
    }
    const char *t[] = {"", "a", "A", "abc", "ABC", "abd", "ab", "abcd",
                       "Hello", "HELLO", "hello", "x", "XyZ", "xyz"};
    const int nt = (int)(sizeof t / sizeof t[0]);
    for (int i = 0; i < nt; i++) for (int j = 0; j < nt; j++) {
        CHECK(sgn(asm_strcmp(t[i], t[j])) == sgn(strcmp(t[i], t[j])), "strcmp2");
        CHECK(sgn(asm_strcasecmp(t[i], t[j])) == sgn(strcasecmp(t[i], t[j])), "strcasecmp");
        for (size_t n = 0; n < 6; n++) {
            CHECK(sgn(asm_strncmp(t[i], t[j], n)) == sgn(strncmp(t[i], t[j], n)), "strncmp2");
            CHECK(sgn(asm_strncasecmp(t[i], t[j], n)) == sgn(strncasecmp(t[i], t[j], n)), "strncasecmp");
        }
    }
}

/*------------------------------------------------------------------------------
 * Searching
 *----------------------------------------------------------------------------*/
static void test_search(void) {
    char s[400];
    memset(s, 'q', sizeof s);           /* define all bytes for valgrind */
    for (int len = 0; len < 160; len++) {
        for (int i = 0; i < len; i++) s[i] = (char)('a' + (rng() % 5));
        if (len) s[rng() % len] = 'Z';
        s[len] = 0;
        for (int off = 0; off < 33 && off <= len; off++) {
            for (int ch = 0; ch < 256; ch += 13) {
                CHECK(asm_strchr(s + off, ch) == strchr(s + off, ch), "strchr");
                CHECK(asm_strrchr(s + off, ch) == strrchr(s + off, ch), "strrchr");
            }
            CHECK(asm_strspn(s + off, "abc") == strspn(s + off, "abc"), "strspn");
            CHECK(asm_strcspn(s + off, "abcZ") == strcspn(s + off, "abcZ"), "strcspn");
            CHECK(asm_strpbrk(s + off, "Zab") == strpbrk(s + off, "Zab"), "strpbrk");
        }
    }
    for (int it = 0; it < 50000; it++) {
        char hay[100], nee[24];
        unsigned char h[100], q[24];
        int hl = rng() % 80, nl = rng() % 14;
        memset(hay, 'h', sizeof hay);   /* define all bytes for valgrind */
        memset(nee, 'n', sizeof nee);
        memset(h, 0x11, sizeof h);
        memset(q, 0x22, sizeof q);
        for (int i = 0; i < hl; i++) hay[i] = (char)('a' + rng() % 3);
        for (int i = 0; i < nl; i++) nee[i] = (char)('a' + rng() % 3);
        hay[hl] = 0; nee[nl] = 0;
        CHECK(asm_strstr(hay, nee) == strstr(hay, nee), "strstr");
        for (int i = 0; i < hl; i++) h[i] = (unsigned char)rng();
        for (int i = 0; i < nl; i++) q[i] = (unsigned char)rng();
        CHECK(asm_memmem(h, hl, q, nl) == memmem(h, hl, q, nl), "memmem");
    }
}

/*------------------------------------------------------------------------------
 * ctype
 *----------------------------------------------------------------------------*/
static void test_ctype(void) {
    for (int c = 0; c < 256; c++) {
        CHECK(asm_toupper(c) == toupper(c), "toupper");
        CHECK(asm_tolower(c) == tolower(c), "tolower");
        CHECK((asm_isalpha(c) != 0) == (isalpha(c) != 0), "isalpha");
        CHECK((asm_isdigit(c) != 0) == (isdigit(c) != 0), "isdigit");
        CHECK((asm_isalnum(c) != 0) == (isalnum(c) != 0), "isalnum");
        CHECK((asm_isspace(c) != 0) == (isspace(c) != 0), "isspace");
        CHECK((asm_isupper(c) != 0) == (isupper(c) != 0), "isupper");
        CHECK((asm_islower(c) != 0) == (islower(c) != 0), "islower");
        CHECK((asm_isxdigit(c) != 0) == (isxdigit(c) != 0), "isxdigit");
        CHECK((asm_isprint(c) != 0) == (isprint(c) != 0), "isprint");
        CHECK((asm_iscntrl(c) != 0) == (iscntrl(c) != 0), "iscntrl");
        CHECK((asm_isgraph(c) != 0) == (isgraph(c) != 0), "isgraph");
        CHECK((asm_ispunct(c) != 0) == (ispunct(c) != 0), "ispunct");
        CHECK((asm_isblank(c) != 0) == (isblank(c) != 0), "isblank");
    }
}

/*------------------------------------------------------------------------------
 * Page-boundary safety
 *------------------------------------------------------------------------------*/
static void test_guards(void) {
    long ps = sysconf(_SC_PAGESIZE);
    size_t map = (size_t)ps * 3;
    unsigned char *region = mmap(NULL, map, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region == MAP_FAILED) { printf("mmap failed\n"); failures++; return; }
    /* protect the final page: any access there faults */
    mprotect(region + 2 * ps, ps, PROT_NONE);
    unsigned char *limit = region + 2 * ps;   /* first protected byte */

    struct sigaction sa, old;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = fault_handler;
    sa.sa_flags = SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old);

    /* ---- strlen/strchr/strcmp with the NUL in the last usable byte -------*/
    for (size_t L = 0; L < 200; L += 3) {
        unsigned char *s = limit - 1 - L;
        for (size_t i = 0; i < L; i++) s[i] = (unsigned char)('a' + (i % 5));
        s[L] = 0;
        CHECK(NO_FAULT(asm_strlen((char *)s) == L), "guard strlen");
        CHECK(NO_FAULT(asm_strnlen((char *)s, L) == L), "guard strnlen");
        CHECK(NO_FAULT(asm_strchr((char *)s, 'z') == NULL), "guard strchr");
        CHECK(NO_FAULT(asm_strrchr((char *)s, 'z') == NULL), "guard strrchr");
        CHECK(NO_FAULT(asm_strchr((char *)s, 'a') == (char *)s), "guard strchr-hit");
        /* strcmp against an identical string placed before the guard */
        CHECK(NO_FAULT(asm_strcmp((char *)s, (char *)s) == 0), "guard strcmp");
        /* bounded reads ending at the guard */
        CHECK(NO_FAULT(asm_memchr(s, 'z', L + 1) == NULL), "guard memchr");
        CHECK(NO_FAULT(asm_memcmp(s, s, L + 1) == 0), "guard memcmp");
        /* strstr with a needle that is not present */
        CHECK(NO_FAULT(asm_strstr((char *)s, "zz") == NULL), "guard strstr");
        /* case-insensitive compare against a mixed-case duplicate */
        {
            unsigned char *t = region + 16;
            for (size_t i = 0; i < L; i++) t[i] = (unsigned char)('A' + (i % 5));
            t[L] = 0;
            CHECK(NO_FAULT(asm_strcasecmp((char *)s, (char *)t) == 0), "guard strcasecmp");
            CHECK(NO_FAULT(asm_strncasecmp((char *)s, (char *)t, L) == 0), "guard strncasecmp");
            CHECK(NO_FAULT(asm_strncasecmp((char *)s, (char *)t, L + 1) == 0), "guard strncasecmp2");
        }
    }

    /* ---- writes ending exactly at the guard -----------------------------*/
    for (volatile size_t n = 1; n < 400; n += 5) {
        unsigned char *d = limit - n;
        CHECK(NO_FAULT(asm_memset(d, 0xAB, n) == d), "guard memset");
        CHECK(NO_FAULT(asm_memcpy(d, region, n) == d), "guard memcpy");
        CHECK(NO_FAULT(asm_bzero(d, n) == d), "guard bzero");
    }

    sigaction(SIGSEGV, &old, NULL);
    munmap(region, map);
}

/*------------------------------------------------------------------------------
 * CPU feature query sanity
 *----------------------------------------------------------------------------*/
static void test_cpu(void) {
    unsigned f = asm_cpu_features();
    /* This library is being exercised, so AVX2/BMI1 must be present. */
    CHECK((f & ASMLIB_CPU_AVX2) != 0, "cpu avx2");
    CHECK((f & ASMLIB_CPU_BMI1) != 0, "cpu bmi1");
    CHECK(asm_cpu_has_avx2() == 1, "cpu has_avx2");
    printf("       cpu features = 0x%02x\n", f);
}

int main(void) {
    printf("== asmlib test suite ==\n");
    test_memory();  printf("   memory   done\n");
    test_large();   printf("   large    done\n");
    test_string();  printf("   string   done\n");
    test_compare(); printf("   compare  done\n");
    test_search();  printf("   search   done\n");
    test_ctype();   printf("   ctype    done\n");
    test_cpu();     printf("   cpu      done\n");
    test_guards();  printf("   guards   done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
