/*==============================================================================
 * test_arena.c - functional and stress tests for the asm arena allocator
 *------------------------------------------------------------------------------
 * Covers fixed and growable arenas, alignment, calloc/realloc, mark/release,
 * reset/destroy, exhaustion, and a randomised overlap stress test. Run under
 * valgrind/ASan it also exercises the backing allocations.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "asmlib.h"

static unsigned long checks = 0;
static unsigned long failures = 0;
#define CHECK(cond, msg)                                                    \
    do {                                                                    \
        checks++;                                                           \
        if (!(cond)) {                                                      \
            printf("FAIL: %-22s line %-4d (%s)\n", (msg), __LINE__, #cond); \
            failures++;                                                     \
        }                                                                   \
    } while (0)

static uint64_t rng_state = 0x9e3779b97f4a7c15ULL;
static uint64_t rng(void) {
    uint64_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return rng_state = x;
}

static void* bk_alloc(size_t n, void* ctx) {
    (void)ctx;
    return malloc(n);
}
static void bk_free(void* p, size_t size, void* ctx) {
    (void)size;
    (void)ctx;
    free(p);
}

/*------------------------------------------------------------------------------
 * Fixed arena: alignment, exhaustion, reset, stats
 *----------------------------------------------------------------------------*/
static void test_fixed(void) {
    static unsigned char buf[1 << 16];
    asm_arena a;
    CHECK(asm_arena_init(&a, buf, sizeof buf) == 0, "init fixed");
    size_t cap = asm_arena_capacity(&a);
    CHECK(cap > 0 && cap <= sizeof buf, "fixed capacity");
    CHECK(asm_arena_used(&a) == 0, "fixed used0");
    CHECK(asm_arena_remaining(&a) == cap, "fixed remaining");

    void* p1 = asm_arena_alloc(&a, 100);
    CHECK(p1 != NULL, "fixed alloc");
    CHECK(((uintptr_t)p1 & 15) == 0, "fixed 16-align");
    memset(p1, 0xAB, 100);
    void* p2 = asm_arena_alloc(&a, 1000);
    CHECK(p2 == (unsigned char*)p1 + 112, "fixed contiguous");
    for (int i = 0; i < 100; i++) CHECK(((unsigned char*)p1)[i] == 0xAB, "fixed pattern intact");

    /* exhaustion must return NULL, never overrun; 16 is the smallest block */
    size_t guard = 0;
    while (asm_arena_alloc(&a, 16) != NULL && guard++ < (1u << 20)) {
    }
    CHECK(asm_arena_alloc(&a, 16) == NULL, "fixed exhaustion NULL");
    CHECK(asm_arena_used(&a) <= cap, "fixed used within capacity");

    /* reset rewinds and reuses the base */
    asm_arena_reset(&a);
    CHECK(asm_arena_used(&a) == 0, "fixed reset used");
    CHECK(asm_arena_remaining(&a) == cap, "fixed reset remaining");
    void* q = asm_arena_alloc(&a, 100);
    CHECK(q == p1, "fixed reset reuses base");

    /* alignment requests */
    for (size_t al = 16; al <= 4096; al <<= 1) {
        void* p = asm_arena_alloc_aligned(&a, 1, al);
        CHECK(p != NULL && ((uintptr_t)p % al) == 0, "fixed align");
    }
    /* bad args */
    CHECK(asm_arena_init(&a, NULL, 0) == -1, "init rejects NULL buf");
    (void)p2;
}

/*------------------------------------------------------------------------------
 * calloc / realloc
 *----------------------------------------------------------------------------*/
static void test_call_realloc(void) {
    static unsigned char buf[1 << 16];
    asm_arena a;
    CHECK(asm_arena_init(&a, buf, sizeof buf) == 0, "init cr");

    unsigned char* c = asm_arena_calloc(&a, 10, 33); /* 330 zero bytes */
    CHECK(c != NULL, "calloc");
    int zero = 1;
    for (int i = 0; i < 330; i++)
        if (c[i]) zero = 0;
    CHECK(zero, "calloc zeroed");
    CHECK(asm_arena_calloc(&a, (size_t)-1, 2) == NULL, "calloc overflow");

    /* realloc of the most recent block grows in place */
    asm_arena_reset(&a);
    unsigned char* p = asm_arena_alloc(&a, 100);
    memset(p, 0x5A, 100);
    unsigned char* r = asm_arena_realloc(&a, p, 100, 200);
    CHECK(r == p, "realloc in place");
    CHECK(p[0] == 0x5A && p[99] == 0x5A, "realloc preserves");
    memset(p, 0x5A, 200); /* define the grown region too */

    /* once another block follows, realloc must move */
    (void)asm_arena_alloc(&a, 50);
    unsigned char* s = asm_arena_realloc(&a, p, 200, 300);
    CHECK(s != NULL && s != p, "realloc moves");
    CHECK(s[0] == 0x5A && s[199] == 0x5A, "realloc move preserves");

    /* realloc(NULL, n) behaves like alloc */
    unsigned char* t = asm_arena_realloc(&a, NULL, 0, 64);
    CHECK(t != NULL, "realloc NULL");
}

/*------------------------------------------------------------------------------
 * Growable arena: growth, reset frees chunks, mark/release
 *----------------------------------------------------------------------------*/
static void test_grow(void) {
    asm_arena a;
    CHECK(asm_arena_init_grow(&a, bk_alloc, bk_free, NULL, 8192) == 0, "init grow");
    CHECK(asm_arena_capacity(&a) == 0, "grow empty capacity");

    void* x = asm_arena_alloc(&a, 100);
    CHECK(x != NULL, "grow alloc");
    memset(x, 0x11, 100);
    size_t cap0 = asm_arena_capacity(&a);
    CHECK(cap0 >= 8192, "grow first chunk");

    /* a mark taken here must survive growth and free the newer chunks */
    asm_mark m;
    asm_arena_mark(&a, &m);
    for (int i = 0; i < 64; i++) {
        void* p = asm_arena_alloc(&a, 1024);
        CHECK(p != NULL, "grow many");
        memset(p, 0x22, 1024);
    }
    CHECK(asm_arena_capacity(&a) > cap0, "grow added chunks");

    CHECK(asm_arena_release(&a, &m) == 0, "release ok");
    CHECK(asm_arena_capacity(&a) == cap0, "release frees newer chunks");
    CHECK(((unsigned char*)x)[0] == 0x11, "release keeps older data");
    void* y = asm_arena_alloc(&a, 100);
    CHECK(y == (unsigned char*)x + 112, "release restores pointer");

    /* mark from a different arena must be rejected */
    asm_arena b;
    CHECK(asm_arena_init_grow(&b, bk_alloc, bk_free, NULL, 8192) == 0, "init grow b");
    void* z = asm_arena_alloc(&b, 16);
    CHECK(z != NULL && asm_arena_release(&a, &m) == 0, "release same arena still ok");
    asm_mark mb;
    asm_arena_mark(&b, &mb);
    CHECK(asm_arena_release(&a, &mb) == -1, "release foreign mark rejected");

    asm_arena_destroy(&a);
    asm_arena_destroy(&b);
}

/*------------------------------------------------------------------------------
 * mmap-backed arena (no libc, no caller allocator)
 *----------------------------------------------------------------------------*/
static void test_mmap(void) {
    asm_arena a;
    CHECK(asm_arena_init_mmap(&a, 16384) == 0, "init mmap");
    void* p = asm_arena_alloc(&a, 100);
    CHECK(p != NULL && ((uintptr_t)p & 15) == 0, "mmap alloc");
    memset(p, 0x77, 100);
    size_t cap0 = asm_arena_capacity(&a);
    CHECK(cap0 >= 16384, "mmap first chunk");
    for (int i = 0; i < 200; i++) {
        void* q = asm_arena_alloc(&a, 1024);
        CHECK(q != NULL, "mmap grow");
        memset(q, 0x33, 1024);
    }
    CHECK(asm_arena_capacity(&a) > cap0, "mmap grew");
    CHECK(((unsigned char*)p)[0] == 0x77, "mmap data intact");
    asm_arena_reset(&a);
    CHECK(asm_arena_capacity(&a) == cap0, "mmap reset shrinks");
    CHECK(asm_arena_used(&a) == 0, "mmap reset used");
    void* q = asm_arena_alloc(&a, 100);
    CHECK(q == p, "mmap reset reuses first chunk");
    asm_arena_destroy(&a);
}

/*------------------------------------------------------------------------------
 * Randomised stress: detect overlaps by tagging every block and re-checking
 *----------------------------------------------------------------------------*/
static void test_stress(void) {
    asm_arena a;
    CHECK(asm_arena_init_grow(&a, bk_alloc, bk_free, NULL, 16384) == 0, "init stress");
    enum { N = 4000 };
    struct rec {
        unsigned char* p;
        size_t sz;
        unsigned char tag;
    }* rec;
    rec = malloc(sizeof *rec * N);
    int nr = 0;
    int bad = 0;
    for (int i = 0; i < N; i++) {
        size_t sz = (size_t)(rng() % 3000) + 1;
        size_t al = (size_t)1 << (4 + (rng() % 5)); /* 16..256 */
        unsigned char* p = asm_arena_alloc_aligned(&a, sz, al);
        if (!p) {
            bad = 1;
            break;
        }
        if (((uintptr_t)p % al) != 0) bad = 1;
        unsigned char tag = (unsigned char)(i * 7 + 1);
        memset(p, tag, sz);
        rec[nr].p = p;
        rec[nr].sz = sz;
        rec[nr].tag = tag;
        nr++;
        /* verify a few earlier blocks are untouched (overlap detector) */
        for (int k = 0; k < 4 && nr > 1; k++) {
            int idx = (int)(rng() % (unsigned)nr);
            if (rec[idx].p[0] != rec[idx].tag || rec[idx].p[rec[idx].sz - 1] != rec[idx].tag)
                bad = 1;
        }
        if (bad) break;
    }
    CHECK(!bad, "stress no overlap/corruption");
    CHECK(asm_arena_used(&a) > 0, "stress used");
    CHECK(asm_arena_capacity(&a) >= asm_arena_used(&a), "stress capacity");

    /* every surviving block still intact */
    int intact = 1;
    for (int i = 0; i < nr; i++) {
        if (rec[i].p[0] != rec[i].tag || rec[i].p[rec[i].sz - 1] != rec[i].tag) {
            intact = 0;
            break;
        }
    }
    CHECK(intact, "stress all blocks intact");

    size_t cap_before = asm_arena_capacity(&a);
    asm_arena_reset(&a);
    CHECK(asm_arena_used(&a) == 0, "stress reset used");
    CHECK(asm_arena_capacity(&a) < cap_before, "stress reset shrinks");
    unsigned char* p = asm_arena_alloc(&a, 64);
    CHECK(p != NULL && ((uintptr_t)p & 15) == 0, "stress reuse after reset");

    free(rec);
    asm_arena_destroy(&a);
}

int main(void) {
    printf("== asm arena test suite ==\n");
    test_fixed();
    printf("   fixed      done\n");
    test_call_realloc();
    printf("   calloc/realloc done\n");
    test_grow();
    printf("   grow       done\n");
    test_mmap();
    printf("   mmap       done\n");
    test_stress();
    printf("   stress     done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
