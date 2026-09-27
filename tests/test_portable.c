/*==============================================================================
 * test_portable.c - differential and page-safety tests for the portable C
 *                   memory/string backend (src/libc/mem.c, src/libc/str.c)
 *------------------------------------------------------------------------------
 * Every function is compared against its host libc counterpart over sizes
 * 0..64 and all alignments/offsets. A guard-page section places destination
 * buffers so their final byte abuts a PROT_NONE page; a SIGSEGV is caught and
 * reported, proving the writers never step out of bounds.
 *
 * Build (default asm_*-prefixed symbols):
 *   cc -O2 -std=c11 -ffreestanding -fno-builtin -fno-stack-protector
 *      -Wall -Wextra -Isrc/libc -o test_portable test_portable.c \
 *      src/libc/mem.c src/libc/str.c
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <unistd.h>

#include "portable.h"

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic ignored "-Wstringop-truncation"
#endif

/*------------------------------------------------------------------------------
 * Tiny test framework
 *----------------------------------------------------------------------------*/
static unsigned long checks = 0;
static unsigned long failures = 0;

#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        checks++;                                                           \
        if (!(cond)) {                                                      \
            printf("FAIL: %-24s line %-4d (%s)\n", (msg), __LINE__, #cond); \
            failures++;                                                     \
        }                                                                   \
    } while (0)

static int sgn(int x) { return (x > 0) - (x < 0); }

/* Deterministic xorshift PRNG so failures are reproducible. */
static uint64_t rng_state = 0x123456789abcdef0ULL;
static uint64_t rng(void) {
    uint64_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return rng_state = x;
}

/*------------------------------------------------------------------------------
 * strlcpy/strlcat host reference (glibc gained them in 2.38)
 *----------------------------------------------------------------------------*/
#if defined(__GLIBC__) && (__GLIBC__ > 2 || __GLIBC_MINOR__ >= 38)
static size_t host_strlcpy(char *dst, const char *src, size_t size) {
    return strlcpy(dst, src, size);
}
static size_t host_strlcat(char *dst, const char *src, size_t size) {
    return strlcat(dst, src, size);
}
#else
static size_t ref_strlcpy(char *dst, const char *src, size_t size) {
    size_t srclen = strlen(src);
    if (size != 0) {
        size_t copy = (srclen < size - 1) ? srclen : size - 1;
        memcpy(dst, src, copy);
        dst[copy] = '\0';
    }
    return srclen;
}
static size_t ref_strlcat(char *dst, const char *src, size_t size) {
    size_t dlen = strnlen(dst, size);
    size_t slen = strlen(src);
    if (dlen == size)
        return size + slen;
    size_t copy = (slen < size - dlen - 1) ? slen : size - dlen - 1;
    memcpy(dst + dlen, src, copy);
    dst[dlen + copy] = '\0';
    return dlen + slen;
}
static size_t host_strlcpy(char *dst, const char *src, size_t size) {
    return ref_strlcpy(dst, src, size);
}
static size_t host_strlcat(char *dst, const char *src, size_t size) {
    return ref_strlcat(dst, src, size);
}
#endif

/*------------------------------------------------------------------------------
 * Memory primitives, sizes 0..64 and every source/destination offset
 *----------------------------------------------------------------------------*/
static void test_memory(void) {
    enum { ARENA = 1024 };
    unsigned char *src = malloc(ARENA);
    unsigned char *exp = malloc(ARENA);
    unsigned char *got = malloc(ARENA);
    if (!src || !exp || !got) { printf("alloc failed\n"); failures++; return; }

    for (size_t i = 0; i < ARENA; i++)
        src[i] = (unsigned char)rng();

    for (size_t n = 0; n <= 64; n++) {
        for (size_t so = 0; so < 8; so++) {
            for (size_t dofs = 0; dofs < 8; dofs++) {
                const unsigned char *s = src + so;
                unsigned char *e = exp + dofs;
                unsigned char *g = got + dofs;

                /* memcpy */
                memset(exp, 0xA5, ARENA);
                memset(got, 0xA5, ARENA);
                memcpy(e, s, n);
                asm_memcpy(g, s, n);
                CHECK(memcmp(exp, got, ARENA) == 0, "memcpy");

                /* mempcpy: identical bytes and dst + n return value */
                memset(exp, 0xA5, ARENA);
                memset(got, 0xA5, ARENA);
                {
                    void *pe = mempcpy(exp + dofs, src + so, n);
                    void *pg = asm_mempcpy(got + dofs, src + so, n);
                    CHECK(pg == got + dofs + n, "mempcpy-ptr");
                    CHECK((size_t)((unsigned char *)pe - exp) ==
                              (size_t)((unsigned char *)pg - got),
                          "mempcpy-host");
                    CHECK(memcmp(exp, got, ARENA) == 0, "mempcpy");
                }

                /* memset */
                memset(exp, 0xA5, ARENA);
                memset(got, 0xA5, ARENA);
                {
                    int c = (int)(rng() & 0xFF);
                    memset(e, c, n);
                    asm_memset(g, c, n);
                    CHECK(memcmp(exp, got, ARENA) == 0, "memset");
                }

                /* bzero */
                memset(exp, 0xA5, ARENA);
                memset(got, 0xA5, ARENA);
                bzero(e, n);
                asm_bzero(g, n);
                CHECK(memcmp(exp, got, ARENA) == 0, "bzero");

                /* explicit_bzero */
                memset(exp, 0xA5, ARENA);
                memset(got, 0xA5, ARENA);
                explicit_bzero(e, n);
                asm_explicit_bzero(g, n);
                CHECK(memcmp(exp, got, ARENA) == 0, "explicit_bzero");

                /* memccpy: c absent (0), a present byte, and random values */
                for (int t = 0; t < 4; t++) {
                    int ch;
                    if (t == 0)
                        ch = 0;
                    else if (t == 1 && n > 0)
                        ch = src[so + (rng() % n)];
                    else if (t == 2 && n > 0)
                        ch = src[so + n - 1];
                    else
                        ch = (int)(rng() & 0xFF);
                    memset(exp, 0xA5, ARENA);
                    memset(got, 0xA5, ARENA);
                    {
                        void *pe = memccpy(exp + dofs, src + so, ch, n);
                        void *pg = asm_memccpy(got + dofs, src + so, ch, n);
                        size_t offe = pe ? (size_t)((unsigned char *)pe - exp) : n;
                        size_t offg = pg ? (size_t)((unsigned char *)pg - got) : n;
                        CHECK((pe == NULL) == (pg == NULL), "memccpy-null");
                        CHECK(offe == offg, "memccpy-ptr");
                        CHECK(memcmp(exp, got, ARENA) == 0, "memccpy");
                    }
                }

                /* memcmp: equal and one differing byte */
                CHECK(sgn(asm_memcmp(s, s, n)) == sgn(memcmp(s, s, n)),
                      "memcmp-eq");
                memcpy(exp, s, n);
                if (n > 0)
                    exp[rng() % n] ^= 0xFF;
                CHECK(sgn(asm_memcmp(s, exp, n)) == sgn(memcmp(s, exp, n)),
                      "memcmp-ne");

                /* memchr / memrchr, including a guaranteed hit */
                for (int t = 0; t < 6; t++) {
                    int ch;
                    if (t == 0)
                        ch = 0;
                    else if (t == 1 && n > 0)
                        ch = src[so + (rng() % n)];
                    else
                        ch = (int)(rng() & 0xFF);
                    CHECK(asm_memchr(src + so, ch, n) ==
                              memchr(src + so, ch, n),
                          "memchr");
                    CHECK(asm_memrchr(src + so, ch, n) ==
                              memrchr(src + so, ch, n),
                          "memrchr");
                }

                /* memmove: disjoint and overlapping in both directions */
                for (long delta = -40; delta <= 40; delta += 5) {
                    long msrc = 512, mdst = 512 + delta;
                    if (mdst < 0 || mdst + (long)n > ARENA)
                        continue;
                    for (size_t i = 0; i < ARENA; i++)
                        exp[i] = got[i] = (unsigned char)(i * 7 + 3);
                    memmove(exp + mdst, exp + msrc, n);
                    asm_memmove(got + mdst, got + msrc, n);
                    CHECK(memcmp(exp, got, ARENA) == 0, "memmove");
                }
            }
        }
    }
    free(src);
    free(exp);
    free(got);
}

/*------------------------------------------------------------------------------
 * String copy/measure, sizes 0..64 and every offset
 *----------------------------------------------------------------------------*/
static void test_string(void) {
    enum { SBUF = 512, DBUF = 600 };
    char *s = malloc(SBUF);
    char *d1 = malloc(DBUF);
    char *d2 = malloc(DBUF);
    if (!s || !d1 || !d2) { printf("alloc failed\n"); failures++; return; }

    memset(s, 0x7A, SBUF);
    for (size_t len = 0; len <= 64; len++) {
        for (size_t i = 0; i < len; i++)
            s[i] = (char)(1 + (rng() % 120));
        s[len] = '\0';
        for (size_t off = 0; off <= len; off++) {
            const char *sp = s + off;
            size_t slen = len - off;

            CHECK(asm_strlen(sp) == strlen(sp), "strlen");
            for (size_t ml = 0; ml <= slen + 3; ml++)
                CHECK(asm_strnlen(sp, ml) == strnlen(sp, ml), "strnlen");

            for (size_t n = 0; n <= slen + 3 && n < DBUF; n++) {
                memset(d1, 0x7E, DBUF);
                memset(d2, 0x7E, DBUF);
                asm_strncpy(d1, sp, n);
                strncpy(d2, sp, n);
                CHECK(memcmp(d1, d2, DBUF) == 0, "strncpy");
            }

            for (size_t n = 0; n <= slen + 3 && n < DBUF; n++) {
                memset(d1, 0x7E, DBUF);
                memset(d2, 0x7E, DBUF);
                {
                    char *r1 = asm_stpncpy(d1, sp, n);
                    char *r2 = stpncpy(d2, sp, n);
                    CHECK((size_t)(r1 - d1) == (size_t)(r2 - d2), "stpncpy-ptr");
                }
                CHECK(memcmp(d1, d2, DBUF) == 0, "stpncpy");
            }

            for (size_t n = 0; n <= slen + 3 && n < 300; n++) {
                memset(d1, 0x55, DBUF);
                memset(d2, 0x55, DBUF);
                strcpy(d1, "pre:");
                strcpy(d2, "pre:");
                asm_strncat(d1, sp, n);
                strncat(d2, sp, n);
                CHECK(memcmp(d1, d2, DBUF) == 0, "strncat");
            }

            for (size_t sz = 0; sz <= slen + 3; sz++) {
                memset(d1, 0x7E, DBUF);
                memset(d2, 0x7E, DBUF);
                {
                    size_t r1 = asm_strlcpy(d1, sp, sz);
                    size_t r2 = host_strlcpy(d2, sp, sz);
                    CHECK(r1 == r2, "strlcpy-ret");
                }
                CHECK(memcmp(d1, d2, DBUF) == 0, "strlcpy");
            }

            for (int ch = 0; ch < 256; ch += 7) {
                CHECK(asm_strchr(sp, ch) == strchr(sp, ch), "strchr");
                CHECK(asm_strrchr(sp, ch) == strrchr(sp, ch), "strrchr");
            }
            CHECK(asm_strchr(sp, 0) == strchr(sp, 0), "strchr-nul");
            CHECK(asm_strrchr(sp, 0) == strrchr(sp, 0), "strrchr-nul");
            if (*sp != '\0') {
                CHECK(asm_strchr(sp, (unsigned char)*sp) ==
                          strchr(sp, (unsigned char)*sp),
                      "strchr-hit");
                CHECK(asm_strrchr(sp, (unsigned char)*sp) ==
                          strrchr(sp, (unsigned char)*sp),
                      "strrchr-hit");
            }

            CHECK(asm_strspn(sp, "abc") == strspn(sp, "abc"), "strspn");
            CHECK(asm_strcspn(sp, "abcZ") == strcspn(sp, "abcZ"), "strcspn");
            CHECK(asm_strpbrk(sp, "Zab") == strpbrk(sp, "Zab"), "strpbrk");
            CHECK(asm_strspn(sp, "") == strspn(sp, ""), "strspn-empty");
            CHECK(asm_strcspn(sp, "") == strcspn(sp, ""), "strcspn-empty");
            CHECK(asm_strpbrk(sp, "") == strpbrk(sp, ""), "strpbrk-empty");
        }
    }
    free(s);
    free(d1);
    free(d2);
}

/*------------------------------------------------------------------------------
 * strlcat - differential append, including the no-NUL-within-size case
 *----------------------------------------------------------------------------*/
static void test_strlcat(void) {
    enum { SB = 300, DB = 512 };
    char *src = malloc(SB);
    char *d1 = malloc(DB);
    char *d2 = malloc(DB);
    if (!src || !d1 || !d2) { printf("alloc failed\n"); failures++; return; }

    memset(src, 0x7A, SB);
    for (size_t len = 0; len < 200; len += 7) {
        for (size_t i = 0; i < len; i++)
            src[i] = (char)(1 + (rng() % 120));
        src[len] = '\0';
        for (size_t dlen = 0; dlen <= 24; dlen++) {
            for (size_t sz = 0; sz <= 48; sz++) {
                memset(d1, 0x55, DB);
                memset(d2, 0x55, DB);
                for (size_t i = 0; i < dlen; i++)
                    d1[i] = d2[i] = (char)('a' + (i % 26));
                d1[dlen] = d2[dlen] = '\0';
                {
                    size_t r1 = asm_strlcat(d1, src, sz);
                    size_t r2 = host_strlcat(d2, src, sz);
                    CHECK(r1 == r2, "strlcat-ret");
                }
                CHECK(memcmp(d1, d2, DB) == 0, "strlcat");
            }
        }
    }
    free(src);
    free(d1);
    free(d2);
}

/*------------------------------------------------------------------------------
 * Comparison
 *----------------------------------------------------------------------------*/
static void test_compare(void) {
    char a[96], b[96];
    memset(a, 'A', sizeof a);
    memset(b, 'B', sizeof b);

    for (int it = 0; it < 20000; it++) {
        int la = (int)(rng() % 60), lb = (int)(rng() % 60);
        for (int i = 0; i < la; i++)
            a[i] = (char)(1 + rng() % 40);
        for (int i = 0; i < lb; i++)
            b[i] = (char)(1 + rng() % 40);
        a[la] = '\0';
        b[lb] = '\0';
        CHECK(sgn(asm_strcmp(a, b)) == sgn(strcmp(a, b)), "strcmp");
        {
            size_t n = rng() % 70;
            CHECK(sgn(asm_strncmp(a, b, n)) == sgn(strncmp(a, b, n)),
                  "strncmp");
        }
    }

    const char *t[] = {"",    "a",    "A",     "abc",  "ABC",   "abd", "ab",
                       "abcd", "Hello", "HELLO", "hello", "x", "XyZ", "xyz"};
    const int nt = (int)(sizeof t / sizeof t[0]);
    for (int i = 0; i < nt; i++) {
        for (int j = 0; j < nt; j++) {
            CHECK(sgn(asm_strcmp(t[i], t[j])) == sgn(strcmp(t[i], t[j])),
                  "strcmp2");
            CHECK(sgn(asm_strcasecmp(t[i], t[j])) ==
                      sgn(strcasecmp(t[i], t[j])),
                  "strcasecmp");
            for (size_t n = 0; n < 6; n++) {
                CHECK(sgn(asm_strncmp(t[i], t[j], n)) ==
                          sgn(strncmp(t[i], t[j], n)),
                      "strncmp2");
                CHECK(sgn(asm_strncasecmp(t[i], t[j], n)) ==
                          sgn(strncasecmp(t[i], t[j], n)),
                      "strncasecmp");
            }
        }
    }
}

/*------------------------------------------------------------------------------
 * Searching
 *----------------------------------------------------------------------------*/
static void test_search(void) {
    char s[400];
    memset(s, 'q', sizeof s);
    for (int len = 0; len < 160; len++) {
        for (int i = 0; i < len; i++)
            s[i] = (char)('a' + (rng() % 5));
        if (len > 0)
            s[rng() % (size_t)len] = 'Z';
        s[len] = '\0';
        for (int off = 0; off < 33 && off <= len; off++) {
            CHECK(asm_strspn(s + off, "abc") == strspn(s + off, "abc"),
                  "strspn2");
            CHECK(asm_strcspn(s + off, "abcZ") == strcspn(s + off, "abcZ"),
                  "strcspn2");
            CHECK(asm_strpbrk(s + off, "Zab") == strpbrk(s + off, "Zab"),
                  "strpbrk2");
        }
    }

    for (int it = 0; it < 50000; it++) {
        char hay[100], nee[24];
        unsigned char h[100], q[24];
        int hl = (int)(rng() % 80), nl = (int)(rng() % 14);
        memset(hay, 'h', sizeof hay);
        memset(nee, 'n', sizeof nee);
        memset(h, 0x11, sizeof h);
        memset(q, 0x22, sizeof q);
        for (int i = 0; i < hl; i++)
            hay[i] = (char)('a' + rng() % 3);
        for (int i = 0; i < nl; i++)
            nee[i] = (char)('a' + rng() % 3);
        hay[hl] = '\0';
        nee[nl] = '\0';
        CHECK(asm_strstr(hay, nee) == strstr(hay, nee), "strstr");
        for (int i = 0; i < hl; i++)
            h[i] = (unsigned char)rng();
        for (int i = 0; i < nl; i++)
            q[i] = (unsigned char)rng();
        CHECK(asm_memmem(h, (size_t)hl, q, (size_t)nl) ==
                  memmem(h, (size_t)hl, q, (size_t)nl),
              "memmem");
    }
}

/*------------------------------------------------------------------------------
 * Page-boundary writers
 *----------------------------------------------------------------------------*/
static sigjmp_buf g_jmp;
static volatile sig_atomic_t g_faulted;

static void fault_handler(int sig) {
    (void)sig;
    g_faulted = 1;
    siglongjmp(g_jmp, 1);
}

#define NO_FAULT(expr) \
    (g_faulted = 0, (sigsetjmp(g_jmp, 1) == 0) ? ((void)(expr), !g_faulted) : 0)

static void test_guards(void) {
    long ps = sysconf(_SC_PAGESIZE);
    size_t map = (size_t)ps * 3;
    unsigned char *region = mmap(NULL, map, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region == MAP_FAILED) { printf("mmap failed\n"); failures++; return; }

    /* Protect the final page: any access there faults. */
    mprotect(region + 2 * ps, (size_t)ps, PROT_NONE);
    unsigned char *limit = region + 2 * ps;

    struct sigaction sa, old;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = fault_handler;
    sa.sa_flags = SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old);

    /* A full page of non-NUL bytes, so bounded writers really write n bytes. */
    memset(region, 'A', (size_t)ps);
    size_t rlen = strlen((char *)region);

    for (size_t n = 1; n < 400; n += 5) {
        unsigned char *d = limit - n;

        CHECK(NO_FAULT(asm_memset(d, 0xAB, n) == d), "guard memset");
        CHECK(NO_FAULT(asm_memcpy(d, region, n) == d), "guard memcpy");
        CHECK(NO_FAULT(asm_memmove(d, region, n) == d), "guard memmove");
        CHECK(NO_FAULT(asm_bzero(d, n) == d), "guard bzero");
        CHECK(NO_FAULT((asm_explicit_bzero(d, n), 1)), "guard explicit_bzero");
        CHECK(NO_FAULT(asm_mempcpy(d, region, n) == d + n), "guard mempcpy");
        /* c == 0 is absent from the source window: copy all n, return NULL. */
        CHECK(NO_FAULT(asm_memccpy(d, region, 0, n) == NULL), "guard memccpy");
        /* src fills n bytes: strncpy writes exactly n, no terminator. */
        CHECK(NO_FAULT(asm_strncpy((char *)d, (char *)region, n) == (char *)d),
              "guard strncpy");
        /* src fills n bytes: stpncpy writes exactly n, returns dst + n. */
        CHECK(NO_FAULT(asm_stpncpy((char *)d, (char *)region, n) ==
                           (char *)d + n),
              "guard stpncpy");
        /* strlcpy/strlcat write n-1 bytes and put the NUL in dst[n-1]. */
        CHECK(NO_FAULT(asm_strlcpy((char *)d, (char *)region, n) == rlen),
              "guard strlcpy");
        d[0] = '\0';
        CHECK(NO_FAULT(asm_strlcat((char *)d, (char *)region, n) == rlen),
              "guard strlcat");
    }

    sigaction(SIGSEGV, &old, NULL);
    munmap(region, map);
}

int main(void) {
    printf("== portable libc test suite ==\n");
    test_memory();  printf("   memory   done\n");
    test_string();  printf("   string   done\n");
    test_strlcat(); printf("   strlcat  done\n");
    test_compare(); printf("   compare  done\n");
    test_search();  printf("   search   done\n");
    test_guards();  printf("   guards   done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
