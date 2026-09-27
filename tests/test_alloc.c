/*==============================================================================
 * test_alloc.c - functional and stress tests for the asm malloc-style heap
 *------------------------------------------------------------------------------
 * Exercises asm_malloc/calloc/realloc/free across the small (slab) and large
 * (per-mapping) paths, verifies 16-byte alignment and content preservation,
 * and runs a randomised alloc/free/realloc stress test that tags every block
 * so any overlap or corruption is detected.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

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

static uint64_t rng_state = 0x2545f4914f6cdd1dULL;
static uint64_t rng(void) {
    uint64_t x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return rng_state = x;
}

/*------------------------------------------------------------------------------
 * Basics: alignment, patterns, calloc, realloc, large mappings
 *----------------------------------------------------------------------------*/
static void test_basics(void) {
    /* a spread of small sizes, all 16-aligned and writable */
    unsigned char *p[64];
    size_t sz[64];
    for (int i = 0; i < 64; i++) {
        sz[i] = (size_t)i * 37 + 1;
        p[i] = asm_malloc(sz[i]);
        CHECK(p[i] != NULL, "small alloc");
        CHECK(((uintptr_t)p[i] & 15) == 0, "small 16-align");
        memset(p[i], 0xA5, sz[i]);
    }
    int ok = 1;
    for (int i = 0; i < 64; i++) {
        for (size_t j = 0; j < sz[i]; j++) if (p[i][j] != 0xA5) ok = 0;
        asm_free(p[i]);
    }
    CHECK(ok, "small pattern intact");

    asm_free(NULL);                      /* must be a no-op */

    /* calloc is zeroed, including a large request */
    unsigned char *c = asm_calloc(1000, 24);
    CHECK(c != NULL, "calloc");
    int zero = 1;
    for (int i = 0; i < 24000; i++) if (c[i]) zero = 0;
    CHECK(zero, "calloc zeroed");
    asm_free(c);
    CHECK(asm_calloc((size_t)-1, 8) == NULL, "calloc overflow");

    /* large allocations go through the mmap path */
    unsigned char *L = asm_malloc(100000);
    CHECK(L != NULL && ((uintptr_t)L & 15) == 0, "large alloc");
    memset(L, 0x5C, 100000);
    CHECK(L[0] == 0x5C && L[99999] == 0x5C, "large pattern");
    asm_free(L);

    /* realloc: grow in place where it fits, move otherwise, preserve bytes */
    unsigned char *r = asm_malloc(100);
    CHECK(r != NULL, "realloc base");
    memset(r, 0x11, 100);
    unsigned char *r2 = asm_realloc(r, 110);     /* same class: in place */
    CHECK(r2 == r, "realloc in place");
    CHECK(r[0] == 0x11 && r[99] == 0x11, "realloc preserve");
    unsigned char *r3 = asm_realloc(r2, 5000);   /* crosses to a large mapping */
    CHECK(r3 != NULL, "realloc grow large");
    CHECK(r3[0] == 0x11 && r3[99] == 0x11, "realloc grow preserve");
    unsigned char *r4 = asm_realloc(r3, 50);     /* shrink */
    CHECK(r4 != NULL && r4[0] == 0x11, "realloc shrink");
    asm_free(r4);

    CHECK(asm_realloc(NULL, 64) != NULL, "realloc NULL");
    unsigned char *rn = asm_malloc(64);
    CHECK(asm_realloc(rn, 0) == NULL, "realloc to 0 frees");
}

/*------------------------------------------------------------------------------
 * reallocarray: overflow rejection and normal resize
 *----------------------------------------------------------------------------*/
static void test_reallocarray(void) {
    unsigned char *p = asm_malloc(64);
    CHECK(p != NULL, "reallocarray base");
    memset(p, 0x3C, 64);

    /* normal resize: 16 * 32 = 512 bytes, contents preserved */
    unsigned char *q = asm_reallocarray(p, 16, 32);
    CHECK(q != NULL, "reallocarray normal");
    CHECK(q[0] == 0x3C && q[63] == 0x3C, "reallocarray preserve");
    CHECK(asm_malloc_usable_size(q) >= 512, "reallocarray usable");

    /* overflow must return NULL and leave q valid */
    CHECK(asm_reallocarray(q, (size_t)-1, 2) == NULL, "reallocarray overflow");
    CHECK(asm_reallocarray(q, 2, (size_t)-1) == NULL, "reallocarray overflow 2");
    CHECK(asm_reallocarray(q, (size_t)-1, (size_t)-1) == NULL, "reallocarray overflow 3");
    CHECK(asm_reallocarray(NULL, (size_t)-1, 2) == NULL, "reallocarray NULL overflow");
    CHECK(q[0] == 0x3C && q[63] == 0x3C, "reallocarray overflow keeps ptr");

    /* count == 0: realloc(p, 0) frees and returns NULL */
    CHECK(asm_reallocarray(q, 0, 8) == NULL, "reallocarray count 0");

    /* NULL ptr with a safe product behaves like malloc */
    unsigned char *r = asm_reallocarray(NULL, 4, 8);
    CHECK(r != NULL && ((uintptr_t)r & 15) == 0, "reallocarray NULL ptr");
    memset(r, 0x71, 32);
    CHECK(r[0] == 0x71 && r[31] == 0x71, "reallocarray NULL writable");
    asm_free(r);
}

/*------------------------------------------------------------------------------
 * malloc_usable_size: >= requested, stable and fully writable
 *----------------------------------------------------------------------------*/
static void test_usable_size(void) {
    CHECK(asm_malloc_usable_size(NULL) == 0, "usable NULL");

    static const size_t sizes[] = {1, 15, 16, 17, 100, 1000, 4080, 4081, 5000, 100000};
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        size_t s = sizes[i];
        unsigned char *p = asm_malloc(s);
        CHECK(p != NULL, "usable alloc");
        size_t u = asm_malloc_usable_size(p);
        CHECK(u >= s, "usable >= request");
        CHECK(asm_malloc_usable_size(p) == u, "usable stable");
        memset(p, 0x77, u);                 /* the whole usable area is writable */
        int intact = 1;
        for (size_t j = 0; j < u; j++) if (p[j] != 0x77) { intact = 0; break; }
        CHECK(intact, "usable writable");
        asm_free(p);
    }

    /* calloc path reports a sane usable size too */
    unsigned char *c = asm_calloc(128, 1);
    CHECK(asm_malloc_usable_size(c) >= 128, "usable calloc");
    asm_free(c);
}

/*------------------------------------------------------------------------------
 * posix_memalign / aligned_alloc across alignments and sizes
 *----------------------------------------------------------------------------*/
static const size_t test_aligns[] = {8, 16, 32, 64, 128, 256, 4096, (size_t)1 << 20};
static const size_t test_sizes[]  = {0, 1, 15, 16, 17, 100, 5000};
#define N_ALIGNS (sizeof test_aligns / sizeof test_aligns[0])
#define N_SIZES  (sizeof test_sizes / sizeof test_sizes[0])

static void test_aligned_alloc(void) {
    for (size_t ai = 0; ai < N_ALIGNS; ai++) {
        size_t align = test_aligns[ai];
        for (size_t si = 0; si < N_SIZES; si++) {
            size_t s = test_sizes[si];

            /* asm_aligned_alloc */
            unsigned char *p = asm_aligned_alloc(align, s);
            CHECK(p != NULL, "aligned_alloc");
            CHECK(((uintptr_t)p & (align - 1)) == 0, "aligned_alloc align");
            CHECK(asm_malloc_usable_size(p) >= s, "aligned_alloc usable");
            if (s) {
                memset(p, 0x5A, s);
                CHECK(p[0] == 0x5A && p[s - 1] == 0x5A, "aligned_alloc writable");
            }
            asm_free(p);

            /* asm_posix_memalign */
            void *q = (void *)(uintptr_t)0x1;
            int rc = asm_posix_memalign(&q, align, s);
            CHECK(rc == 0, "posix_memalign rc");
            CHECK(q != NULL, "posix_memalign ptr");
            CHECK(((uintptr_t)q & (align - 1)) == 0, "posix_memalign align");
            CHECK(asm_malloc_usable_size(q) >= s, "posix_memalign usable");
            if (s) {
                memset(q, 0xA6, s);
                CHECK(((unsigned char *)q)[0] == 0xA6 &&
                      ((unsigned char *)q)[s - 1] == 0xA6, "posix_memalign writable");
            }
            asm_free(q);
        }
    }

    /* invalid alignments: posix returns EINVAL and leaves *memptr untouched */
    static const size_t bad[] = {0, 3, 24, 5, 6, 7, 48};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        void *sentinel = (void *)(uintptr_t)0xDEADBEEF;
        void *q = sentinel;
        CHECK(asm_posix_memalign(&q, bad[i], 16) == 22, "posix EINVAL");
        CHECK(q == sentinel, "posix leaves memptr");
    }
    /* power-of-two but below sizeof(void*) is also EINVAL for posix */
    { void *q = (void *)(uintptr_t)0x1; CHECK(asm_posix_memalign(&q, 1, 16) == 22, "posix EINVAL 1"); }
    { void *q = (void *)(uintptr_t)0x1; CHECK(asm_posix_memalign(&q, 4, 16) == 22, "posix EINVAL 4"); }

    /* invalid alignments: aligned_alloc returns NULL */
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
        CHECK(asm_aligned_alloc(bad[i], 16) == NULL, "aligned_alloc bad align");
    CHECK(asm_aligned_alloc(0, 16) == NULL, "aligned_alloc 0");
}

/*------------------------------------------------------------------------------
 * Free a mix of over-aligned and ordinary blocks in a scrambled order
 *----------------------------------------------------------------------------*/
static void test_mixed_free(void) {
    enum { M = 512 };
    unsigned char *ptrs[M];
    size_t sx[M];
    for (int i = 0; i < M; i++) {
        sx[i] = (size_t)(i % 7) * 300 + (size_t)(i % 5) + 1;
        if (i % 3 == 0) {
            size_t al = (size_t)1 << (4 + (i % 5));   /* 16..256 */
            ptrs[i] = asm_aligned_alloc(al, sx[i]);
        } else {
            ptrs[i] = asm_malloc(sx[i]);
        }
        CHECK(ptrs[i] != NULL, "mixed alloc");
        memset(ptrs[i], (unsigned char)(i | 1), sx[i]);
    }
    int intact = 1;
    for (int i = 0; i < M; i++) {
        int k = (i * 167 + 13) % M;             /* a permutation of 0..M-1 */
        if (ptrs[k][0] != (unsigned char)(k | 1)) intact = 0;
        asm_free(ptrs[k]);
    }
    CHECK(intact, "mixed free intact");
}

/*------------------------------------------------------------------------------
 * Randomised alloc/free/realloc stress with content tagging
 *----------------------------------------------------------------------------*/
static void test_stress(void) {
    enum { N = 4096 };
    struct rec { unsigned char *p; size_t sz; unsigned char tag; int live; } *rec;
    int *freestack;
    rec = calloc(N, sizeof *rec);
    freestack = malloc(N * sizeof *freestack);
    int nfree = 0, nslots = 0, bad = 0;

    for (int iter = 0; iter < 200000 && !bad; iter++) {
        int action = (int)(rng() % 100);
        if (nslots == 0 || action < 55) {
            size_t s = 1 + (size_t)(rng() % 3000);
            int idx;
            if (nfree > 0) idx = freestack[--nfree];
            else if (nslots < N) idx = nslots++;
            else continue;                       /* table full: skip */
            unsigned char *p = asm_malloc(s);
            if (!p || ((uintptr_t)p & 15)) { bad = 1; break; }
            unsigned char tag = (unsigned char)(rng() | 1);
            memset(p, tag, s);
            rec[idx].p = p; rec[idx].sz = s; rec[idx].tag = tag; rec[idx].live = 1;
        } else if (action < 75) {
            int idx = (int)(rng() % (unsigned)nslots);
            if (!rec[idx].live) continue;
            if (rec[idx].p[0] != rec[idx].tag || rec[idx].p[rec[idx].sz - 1] != rec[idx].tag) { bad = 1; break; }
            asm_free(rec[idx].p);
            rec[idx].live = 0;
            freestack[nfree++] = idx;
        } else {
            int idx = (int)(rng() % (unsigned)nslots);
            if (!rec[idx].live) continue;
            size_t newsz = 1 + (size_t)(rng() % 4000);
            size_t keep = rec[idx].sz < newsz ? rec[idx].sz : newsz;
            unsigned char oldtag = rec[idx].tag;
            unsigned char *np = asm_realloc(rec[idx].p, newsz);
            if (!np || ((uintptr_t)np & 15)) { bad = 1; break; }
            if (np[0] != oldtag || np[keep - 1] != oldtag) { bad = 1; break; }
            unsigned char tag = (unsigned char)(rng() | 1);
            memset(np, tag, newsz);
            rec[idx].p = np; rec[idx].sz = newsz; rec[idx].tag = tag; rec[idx].live = 1;
        }
    }
    CHECK(!bad, "stress no overlap/corruption");

    /* free everything still live, re-verifying first */
    int intact = 1;
    for (int i = 0; i < nslots; i++) {
        if (!rec[i].live) continue;
        if (rec[i].p[0] != rec[i].tag || rec[i].p[rec[i].sz - 1] != rec[i].tag) intact = 0;
        asm_free(rec[i].p);
    }
    CHECK(intact, "stress all live blocks intact");
    free(freestack);
    free(rec);
}

/*------------------------------------------------------------------------------
 * Randomised stress mixing over-aligned and ordinary allocations
 *----------------------------------------------------------------------------*/
static void test_stress_aligned(void) {
    enum { N = 2048 };
    struct rec { unsigned char *p; size_t sz; unsigned char tag; int live; } *rec;
    int *freestack;
    rec = calloc(N, sizeof *rec);
    freestack = malloc(N * sizeof *freestack);
    int nfree = 0, nslots = 0, bad = 0;

    static const size_t align_choices[] = {0, 32, 64, 128, 256, 512, 4096};

    for (int iter = 0; iter < 120000 && !bad; iter++) {
        int action = (int)(rng() % 100);
        if (nslots == 0 || action < 50) {
            size_t s = 1 + (size_t)(rng() % 8000);
            int idx;
            if (nfree > 0) idx = freestack[--nfree];
            else if (nslots < N) idx = nslots++;
            else continue;
            size_t al = align_choices[rng() % (sizeof align_choices / sizeof align_choices[0])];
            unsigned char *p = al ? asm_aligned_alloc(al, s) : asm_malloc(s);
            if (!p) { bad = 1; break; }
            if (al && ((uintptr_t)p & (al - 1)) != 0) { bad = 1; break; }
            if (asm_malloc_usable_size(p) < s) { bad = 1; break; }
            unsigned char tag = (unsigned char)(rng() | 1);
            memset(p, tag, s);
            rec[idx].p = p; rec[idx].sz = s; rec[idx].tag = tag; rec[idx].live = 1;
        } else if (action < 72) {
            int idx = (int)(rng() % (unsigned)nslots);
            if (!rec[idx].live) continue;
            if (rec[idx].p[0] != rec[idx].tag ||
                rec[idx].p[rec[idx].sz - 1] != rec[idx].tag) { bad = 1; break; }
            asm_free(rec[idx].p);
            rec[idx].live = 0;
            freestack[nfree++] = idx;
        } else {
            int idx = (int)(rng() % (unsigned)nslots);
            if (!rec[idx].live) continue;
            size_t newsz = 1 + (size_t)(rng() % 8000);
            size_t keep = rec[idx].sz < newsz ? rec[idx].sz : newsz;
            unsigned char oldtag = rec[idx].tag;
            unsigned char *np = asm_realloc(rec[idx].p, newsz);
            if (!np) { bad = 1; break; }
            if (np[0] != oldtag || np[keep - 1] != oldtag) { bad = 1; break; }
            unsigned char tag = (unsigned char)(rng() | 1);
            memset(np, tag, newsz);
            rec[idx].p = np; rec[idx].sz = newsz; rec[idx].tag = tag; rec[idx].live = 1;
        }
    }
    CHECK(!bad, "aligned stress no corruption");

    /* free everything still live, re-verifying first */
    int intact = 1;
    for (int i = 0; i < nslots; i++) {
        if (!rec[i].live) continue;
        if (rec[i].p[0] != rec[i].tag || rec[i].p[rec[i].sz - 1] != rec[i].tag) intact = 0;
        asm_free(rec[i].p);
    }
    CHECK(intact, "aligned stress live intact");
    free(freestack);
    free(rec);
}

int main(void) {
    printf("== asm malloc test suite ==\n");
    test_basics();
    printf("   basics       done\n");
    test_reallocarray();
    printf("   reallocarray done\n");
    test_usable_size();
    printf("   usable size  done\n");
    test_aligned_alloc();
    printf("   aligned      done\n");
    test_mixed_free();
    printf("   mixed free   done\n");
    test_stress();
    printf("   stress       done\n");
    test_stress_aligned();
    printf("   align stress done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
