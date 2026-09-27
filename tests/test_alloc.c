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

int main(void) {
    printf("== asm malloc test suite ==\n");
    test_basics();
    printf("   basics     done\n");
    test_stress();
    printf("   stress     done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
