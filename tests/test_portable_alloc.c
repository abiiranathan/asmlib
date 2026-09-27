/*==============================================================================
 * test_portable_alloc.c - tests for the portable freestanding C allocator
 *------------------------------------------------------------------------------
 * Drives src/libc/alloc.c through the portable API (asm_malloc, ...): checks
 * 16-byte alignment, calloc zeroing, usable sizes, realloc content
 * preservation, overflow rejection, over-aligned allocation across alignments,
 * invalid-alignment handling, a scrambled free mix and a 200k-operation
 * randomised malloc/calloc/realloc/free stress that tags every block so any
 * overlap or corruption is detected.
 *
 * Build:
 *   cc -O2 -std=c11 -ffreestanding -fno-builtin -fno-stack-protector \
 *      -Wall -Wextra -Isrc/libc -o test_portable_alloc \
 *      tests/test_portable_alloc.c src/libc/alloc.c
 *============================================================================*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>

#include "portable.h"

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

#define ASM_ALIGN 16u

static uint64_t rng_state = 0x9e3779b97f4a7c15ULL;
static uint64_t rng(void) {
    uint64_t x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return rng_state = x;
}

static int is_aligned(const void *p, size_t a) {
    return ((uintptr_t)p & (a - 1)) == 0;
}

/*------------------------------------------------------------------------------
 * Basics: alignment, writability, calloc zeroing and usable size
 *----------------------------------------------------------------------------*/
static void test_basics(void) {
    unsigned char *p[128];
    size_t sz[128];

    for (int i = 0; i < 128; i++) {
        sz[i] = (size_t)i * 53 + 1;
        p[i] = ASM_LIBC(malloc)(sz[i]);
        CHECK(p[i] != NULL, "malloc");
        CHECK(is_aligned(p[i], ASM_ALIGN), "malloc 16-align");
        CHECK(ASM_LIBC(malloc_usable_size)(p[i]) >= sz[i], "usable >= request");
        memset(p[i], 0xC3, sz[i]);
    }
    int intact = 1;
    for (int i = 0; i < 128; i++) {
        for (size_t j = 0; j < sz[i]; j++) if (p[i][j] != 0xC3) intact = 0;
        ASM_LIBC(free)(p[i]);
    }
    CHECK(intact, "pattern intact");

    ASM_LIBC(free)(NULL);
    CHECK(ASM_LIBC(malloc_usable_size)(NULL) == 0, "usable NULL");

    /* malloc(0) still yields a unique, aligned, freeable pointer */
    void *z1 = ASM_LIBC(malloc)(0);
    void *z2 = ASM_LIBC(malloc)(0);
    CHECK(z1 != NULL && z2 != NULL && z1 != z2, "malloc(0) unique");
    CHECK(is_aligned(z1, ASM_ALIGN) && is_aligned(z2, ASM_ALIGN), "malloc(0) align");
    ASM_LIBC(free)(z1);
    ASM_LIBC(free)(z2);

    /* calloc zeroes its whole request */
    unsigned char *c = ASM_LIBC(calloc)(997, 24);
    CHECK(c != NULL, "calloc");
    CHECK(is_aligned(c, ASM_ALIGN), "calloc align");
    int zero = 1;
    for (size_t i = 0; i < 997 * 24; i++) if (c[i]) zero = 0;
    CHECK(zero, "calloc zeroed");
    CHECK(ASM_LIBC(malloc_usable_size)(c) >= 997 * 24, "calloc usable");
    ASM_LIBC(free)(c);

    unsigned char *cz = ASM_LIBC(calloc)(0, 0);
    CHECK(cz != NULL, "calloc(0,0)");
    ASM_LIBC(free)(cz);

    CHECK(ASM_LIBC(calloc)((size_t)-1, 8) == NULL, "calloc overflow");
    CHECK(ASM_LIBC(calloc)(8, (size_t)-1) == NULL, "calloc overflow 2");
}

/*------------------------------------------------------------------------------
 * realloc: grow, shrink, content preservation, NULL and zero size
 *----------------------------------------------------------------------------*/
static void test_realloc(void) {
    unsigned char *p = ASM_LIBC(malloc)(100);
    CHECK(p != NULL, "realloc base");
    memset(p, 0x5A, 100);

    unsigned char *g = ASM_LIBC(realloc)(p, 4000);
    CHECK(g != NULL, "realloc grow");
    CHECK(is_aligned(g, ASM_ALIGN), "realloc grow align");
    CHECK(g[0] == 0x5A && g[99] == 0x5A, "realloc grow preserved");

    unsigned char *s = ASM_LIBC(realloc)(g, 32);
    CHECK(s != NULL, "realloc shrink");
    CHECK(s[0] == 0x5A && s[31] == 0x5A, "realloc shrink preserved");
    CHECK(ASM_LIBC(malloc_usable_size)(s) >= 32, "realloc shrink usable");
    ASM_LIBC(free)(s);

    CHECK(ASM_LIBC(realloc)(NULL, 64) != NULL, "realloc NULL -> malloc");

    unsigned char *q = ASM_LIBC(malloc)(64);
    CHECK(q != NULL, "realloc zero base");
    CHECK(ASM_LIBC(realloc)(q, 0) == NULL, "realloc to 0 frees");
}

/*------------------------------------------------------------------------------
 * reallocarray: overflow rejection keeps the pointer valid
 *----------------------------------------------------------------------------*/
static void test_reallocarray(void) {
    unsigned char *p = ASM_LIBC(malloc)(64);
    CHECK(p != NULL, "reallocarray base");
    memset(p, 0x3C, 64);

    CHECK(ASM_LIBC(reallocarray)(p, (size_t)-1, 2) == NULL, "reallocarray overflow");
    CHECK(ASM_LIBC(reallocarray)(p, 2, (size_t)-1) == NULL, "reallocarray overflow 2");
    CHECK(ASM_LIBC(reallocarray)(p, (size_t)-1, (size_t)-1) == NULL, "reallocarray overflow 3");
    CHECK(ASM_LIBC(reallocarray)(NULL, (size_t)-1, 2) == NULL, "reallocarray NULL overflow");
    CHECK(p[0] == 0x3C && p[63] == 0x3C, "reallocarray overflow keeps ptr");

    unsigned char *q = ASM_LIBC(reallocarray)(p, 16, 32);
    CHECK(q != NULL, "reallocarray normal");
    CHECK(q[0] == 0x3C && q[63] == 0x3C, "reallocarray preserve");
    CHECK(ASM_LIBC(malloc_usable_size)(q) >= 512, "reallocarray usable");
    ASM_LIBC(free)(q);
}

/*------------------------------------------------------------------------------
 * posix_memalign / aligned_alloc across alignments, with free and realloc
 *----------------------------------------------------------------------------*/
static const size_t test_aligns[] = {16, 32, 64, 256, 4096};
static const size_t test_sizes[]  = {0, 1, 15, 16, 17, 100, 5000};
#define N_ALIGNS (sizeof test_aligns / sizeof test_aligns[0])
#define N_SIZES  (sizeof test_sizes / sizeof test_sizes[0])

static void test_aligned(void) {
    for (size_t ai = 0; ai < N_ALIGNS; ai++) {
        size_t a = test_aligns[ai];
        for (size_t si = 0; si < N_SIZES; si++) {
            size_t s = test_sizes[si];

            unsigned char *p = ASM_LIBC(aligned_alloc)(a, s);
            CHECK(p != NULL, "aligned_alloc");
            CHECK(is_aligned(p, a), "aligned_alloc align");
            CHECK(is_aligned(p, ASM_ALIGN), "aligned_alloc 16-align");
            CHECK(ASM_LIBC(malloc_usable_size)(p) >= s, "aligned_alloc usable");
            if (s) {
                memset(p, 0x5A, s);
                CHECK(p[0] == 0x5A && p[s - 1] == 0x5A, "aligned_alloc writable");
            }
            ASM_LIBC(free)(p);

            void *q = (void *)(uintptr_t)0x1;
            int rc = ASM_LIBC(posix_memalign)(&q, a, s);
            CHECK(rc == 0, "posix_memalign rc");
            CHECK(q != NULL && is_aligned(q, a), "posix_memalign align");
            CHECK(ASM_LIBC(malloc_usable_size)(q) >= s, "posix_memalign usable");
            if (s) {
                memset(q, 0xA6, s);
                CHECK(((unsigned char *)q)[0] == 0xA6 &&
                      ((unsigned char *)q)[s - 1] == 0xA6, "posix_memalign writable");
            }
            ASM_LIBC(free)(q);
        }
    }

    /* grow and shrink a live over-aligned block, preserving its bytes */
    unsigned char *r = ASM_LIBC(aligned_alloc)(256, 64);
    CHECK(r != NULL && is_aligned(r, 256), "aligned realloc base");
    memset(r, 0x77, 64);
    unsigned char *r2 = ASM_LIBC(realloc)(r, 3000);
    CHECK(r2 != NULL && is_aligned(r2, ASM_ALIGN), "aligned realloc grow");
    CHECK(r2[0] == 0x77 && r2[63] == 0x77, "aligned realloc preserved");
    unsigned char *r3 = ASM_LIBC(realloc)(r2, 16);
    CHECK(r3 != NULL && r3[0] == 0x77 && r3[15] == 0x77, "aligned realloc shrink");
    ASM_LIBC(free)(r3);

    /* posix_memalign must accept 8 (== sizeof(void*)) and reject 1 and 4 */
    { void *q = NULL; CHECK(ASM_LIBC(posix_memalign)(&q, 8, 32) == 0 && is_aligned(q, 8), "posix align 8"); ASM_LIBC(free)(q); }
    { void *q = NULL; CHECK(ASM_LIBC(posix_memalign)(&q, 1, 32) == 22, "posix reject 1"); }
    { void *q = NULL; CHECK(ASM_LIBC(posix_memalign)(&q, 4, 32) == 22, "posix reject 4"); }

    /* invalid alignments: posix returns EINVAL and leaves *memptr untouched */
    static const size_t bad[] = {0, 3, 24, 5, 6, 7, 48};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        void *sentinel = (void *)(uintptr_t)0xDEADBEEF;
        void *q = sentinel;
        CHECK(ASM_LIBC(posix_memalign)(&q, bad[i], 16) == 22, "posix EINVAL");
        CHECK(q == sentinel, "posix leaves memptr");
        CHECK(ASM_LIBC(aligned_alloc)(bad[i], 16) == NULL, "aligned_alloc bad align");
    }
    CHECK(ASM_LIBC(aligned_alloc)(0, 16) == NULL, "aligned_alloc 0");
}

/*------------------------------------------------------------------------------
 * Free a scrambled mix of plain and over-aligned blocks
 *----------------------------------------------------------------------------*/
static void test_scrambled_mix(void) {
    enum { M = 600 };
    unsigned char *ptrs[M];
    size_t sx[M];

    for (int i = 0; i < M; i++) {
        sx[i] = (size_t)(i % 9) * 350 + (size_t)(i % 7) + 1;
        if (i % 3 == 0) {
            size_t a = (size_t)1 << (4 + (i % 5));   /* 16..256 */
            ptrs[i] = ASM_LIBC(aligned_alloc)(a, sx[i]);
        } else {
            ptrs[i] = ASM_LIBC(malloc)(sx[i]);
        }
        CHECK(ptrs[i] != NULL, "mix alloc");
        CHECK(is_aligned(ptrs[i], ASM_ALIGN), "mix align");
        memset(ptrs[i], (unsigned char)(i | 1), sx[i]);
    }

    int intact = 1;
    for (int i = 0; i < M; i++) {
        int k = (i * 331 + 17) % M;                  /* permutation of 0..M-1 */
        if (ptrs[k][0] != (unsigned char)(k | 1) ||
            ptrs[k][sx[k] - 1] != (unsigned char)(k | 1)) intact = 0;
        ASM_LIBC(free)(ptrs[k]);
    }
    CHECK(intact, "mix free intact");

    /* Churn: allocate, free even indices, then confirm odd blocks survive */
    enum { K = 256 };
    unsigned char *keep[K];
    for (int i = 0; i < K; i++) {
        keep[i] = ASM_LIBC(malloc)((size_t)(i + 1) * 13);
        CHECK(keep[i] != NULL, "churn alloc");
        memset(keep[i], (unsigned char)(i + 2), (size_t)(i + 1) * 13);
    }
    for (int i = 0; i < K; i += 2) ASM_LIBC(free)(keep[i]);
    int churn_ok = 1;
    for (int i = 1; i < K; i += 2) {
        size_t n = (size_t)(i + 1) * 13;
        if (keep[i][0] != (unsigned char)(i + 2) || keep[i][n - 1] != (unsigned char)(i + 2)) churn_ok = 0;
    }
    CHECK(churn_ok, "churn survivors intact");
    for (int i = 1; i < K; i += 2) ASM_LIBC(free)(keep[i]);
}

/*------------------------------------------------------------------------------
 * 200k-operation randomised malloc/calloc/realloc/free stress with tagging
 *----------------------------------------------------------------------------*/
static void test_stress(void) {
    enum { N = 2048 };
    struct rec {
        unsigned char *p;
        size_t sz;
        unsigned char tag;
        int live;
    } *rec;
    int *freestack;
    int nfree = 0, nslots = 0, bad = 0;

    rec = malloc(N * sizeof *rec);
    freestack = malloc(N * sizeof *freestack);
    CHECK(rec != NULL && freestack != NULL, "stress table");
    if (rec == NULL || freestack == NULL) { free(rec); free(freestack); return; }

    for (int iter = 0; iter < 200000 && !bad; iter++) {
        int action = (int)(rng() % 100);

        if (nslots == 0 || action < 52) {
            size_t s = 1 + (size_t)(rng() % 4096);
            int idx;
            if (nfree > 0) idx = freestack[--nfree];
            else if (nslots < N) idx = nslots++;
            else continue;

            int use_calloc = (int)(rng() & 1);
            unsigned char *p = use_calloc ? ASM_LIBC(calloc)(1, s) : ASM_LIBC(malloc)(s);
            if (p == NULL || !is_aligned(p, ASM_ALIGN)) { bad = 1; break; }
            if (ASM_LIBC(malloc_usable_size)(p) < s) { bad = 1; break; }
            if (use_calloc) {
                for (size_t j = 0; j < s; j++) if (p[j] != 0) { bad = 1; break; }
                if (bad) break;
            }
            {
                unsigned char tag = (unsigned char)(rng() | 1);
                memset(p, tag, s);
                rec[idx].p = p; rec[idx].sz = s; rec[idx].tag = tag; rec[idx].live = 1;
            }
        } else if (action < 74) {
            int idx = (int)(rng() % (unsigned)nslots);
            if (!rec[idx].live) continue;
            if (rec[idx].p[0] != rec[idx].tag ||
                rec[idx].p[rec[idx].sz - 1] != rec[idx].tag) { bad = 1; break; }
            ASM_LIBC(free)(rec[idx].p);
            rec[idx].live = 0;
            freestack[nfree++] = idx;
        } else {
            int idx = (int)(rng() % (unsigned)nslots);
            if (!rec[idx].live) continue;
            size_t newsz = 1 + (size_t)(rng() % 5000);
            size_t keep = rec[idx].sz < newsz ? rec[idx].sz : newsz;
            unsigned char oldtag = rec[idx].tag;
            unsigned char *np = ASM_LIBC(realloc)(rec[idx].p, newsz);
            if (np == NULL || !is_aligned(np, ASM_ALIGN)) { bad = 1; break; }
            if (np[0] != oldtag || np[keep - 1] != oldtag) { bad = 1; break; }
            {
                unsigned char tag = (unsigned char)(rng() | 1);
                memset(np, tag, newsz);
                rec[idx].p = np; rec[idx].sz = newsz; rec[idx].tag = tag; rec[idx].live = 1;
            }
        }
    }
    CHECK(!bad, "stress no overlap/corruption");

    int intact = 1;
    for (int i = 0; i < nslots; i++) {
        if (!rec[i].live) continue;
        if (rec[i].p[0] != rec[i].tag || rec[i].p[rec[i].sz - 1] != rec[i].tag) intact = 0;
        ASM_LIBC(free)(rec[i].p);
    }
    CHECK(intact, "stress live blocks intact");

    free(freestack);
    free(rec);
}

int main(void) {
    printf("== portable allocator test suite ==\n");
    test_basics();
    printf("   basics       done\n");
    test_realloc();
    printf("   realloc      done\n");
    test_reallocarray();
    printf("   reallocarray done\n");
    test_aligned();
    printf("   aligned      done\n");
    test_scrambled_mix();
    printf("   scrambled    done\n");
    test_stress();
    printf("   stress       done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
