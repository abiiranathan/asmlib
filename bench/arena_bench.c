/*==============================================================================
 * arena_bench.c - asm arena allocator vs malloc/memset
 *------------------------------------------------------------------------------
 * Compares the arena against malloc/free for the workloads arenas are built
 * for:
 *   - many small fixed-size allocations followed by a reset
 *   - a mixed-size allocation burst (parser/compiler style)
 *   - allocating and touching the memory (locality matters here)
 *   - the cost of rewinding versus freeing every block
 *
 * Each measurement is the best of several trials to limit scheduler noise.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

#include "asmlib.h"

#define TRIALS 9
#define N_SMALL 1000
#define N_MIXED 4000
#define SMALLSZ 64
#define MAXBLK 512
#define ARENA_BYTES (8u << 20)

static volatile size_t sink;

static double now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e9 + t.tv_nsec;
}

typedef void (*workfn)(void);

static double best(workfn fn) {
    double b = 1e30;
    for (int t = 0; t < TRIALS; t++) {
        double a = now_ns();
        fn();
        double c = now_ns();
        if (c - a < b) b = c - a;
    }
    return b;
}

static asm_arena A;
static unsigned char *fbuf;
static void *ptrs[N_MIXED];
static size_t sizes[N_MIXED];

/*------------------------------------------------------------------------------
 * Workloads
 *----------------------------------------------------------------------------*/

/* fixed 64-byte allocations, arena */
static void arena_small(void) {
    asm_arena_reset(&A);
    for (int i = 0; i < N_SMALL; i++) {
        unsigned char *p = asm_arena_alloc(&A, SMALLSZ);
        sink += p[0];
    }
}
/* fixed 64-byte allocations, malloc/free */
static void malloc_small(void) {
    for (int i = 0; i < N_SMALL; i++) ptrs[i] = malloc(SMALLSZ);
    for (int i = 0; i < N_SMALL; i++) free(ptrs[i]);
}

/* mixed-size burst, arena */
static void arena_mixed(void) {
    asm_arena_reset(&A);
    for (int i = 0; i < N_MIXED; i++) {
        unsigned char *p = asm_arena_alloc(&A, sizes[i]);
        sink += p[0];
    }
}
/* mixed-size burst, malloc/free */
static void malloc_mixed(void) {
    for (int i = 0; i < N_MIXED; i++) ptrs[i] = malloc(sizes[i]);
    for (int i = 0; i < N_MIXED; i++) free(ptrs[i]);
}

/* allocate and touch 64 bytes (cache locality), arena */
static void arena_touch(void) {
    asm_arena_reset(&A);
    for (int i = 0; i < N_SMALL; i++) {
        unsigned char *p = asm_arena_alloc(&A, SMALLSZ);
        asm_memset(p, i & 0xff, SMALLSZ);
        sink += p[SMALLSZ - 1];
    }
}
/* allocate and touch 64 bytes, malloc/memset/free */
static void malloc_touch(void) {
    for (int i = 0; i < N_SMALL; i++) {
        unsigned char *p = malloc(SMALLSZ);
        asm_memset(p, i & 0xff, SMALLSZ);
        ptrs[i] = p;
    }
    for (int i = 0; i < N_SMALL; i++) {
        sink += ((unsigned char *)ptrs[i])[SMALLSZ - 1];
        free(ptrs[i]);
    }
}

/*------------------------------------------------------------------------------
 * asm_malloc vs libc malloc
 *----------------------------------------------------------------------------*/
static void amalloc_small(void) {
    for (int i = 0; i < N_SMALL; i++) ptrs[i] = asm_malloc(SMALLSZ);
    for (int i = 0; i < N_SMALL; i++) asm_free(ptrs[i]);
}
static void amalloc_mixed(void) {
    for (int i = 0; i < N_MIXED; i++) ptrs[i] = asm_malloc(sizes[i]);
    for (int i = 0; i < N_MIXED; i++) asm_free(ptrs[i]);
}

/*------------------------------------------------------------------------------
 * Reset cost: a fixed arena's O(1) reset vs freeing every block
 *----------------------------------------------------------------------------*/
static unsigned char *gbuf;
static asm_arena G;
static void *gp[4096];
static int gcount;

static void fill_burst(void) {
    gcount = 0;
    for (int i = 0; i < 2048; i++) {
        void *p = asm_arena_alloc(&G, 1024);
        if (!p) break;
        ((char *)p)[0] = 1;
        gcount++;
    }
}
static void arena_fill_reset(void) {
    fill_burst();                       /* 2048 x 1 KiB from one buffer */
    asm_arena_reset(&G);                /* O(1) rewind, no free calls   */
}
static void malloc_free_all(void) {
    for (int i = 0; i < gcount; i++) gp[i] = malloc(1024);
    for (int i = 0; i < gcount; i++) free(gp[i]);
}

int main(void) {
    fbuf = asm_sys_mmap(ARENA_BYTES);          /* arena memory straight from mmap */
    if (!fbuf || asm_arena_init(&A, fbuf, ARENA_BYTES) != 0) {
        printf("arena init failed\n"); return 1;
    }
    gbuf = asm_sys_mmap(4u << 20);
    if (!gbuf || asm_arena_init(&G, gbuf, 4u << 20) != 0) {
        printf("fixed reset arena init failed\n"); return 1;
    }
    srand(42);
    for (int i = 0; i < N_MIXED; i++) sizes[i] = 8 + (size_t)(rand() % (MAXBLK - 8));

    printf("asm allocators vs libc malloc (best of %d; lower is better)\n", TRIALS);
    printf("%-28s %12s %12s %9s\n", "workload", "asm", "malloc", "speedup");
    printf("%-28s %12s %12s %9s\n", "", "ns/op", "ns/op", "");

    double a1 = best(arena_small), m1 = best(malloc_small);
    printf("%-28s %12.2f %12.2f %8.2fx\n",
           "arena   1000 x 64B", a1 / N_SMALL, m1 / N_SMALL, m1 / a1);

    double a2 = best(arena_mixed), m2 = best(malloc_mixed);
    printf("%-28s %12.2f %12.2f %8.2fx\n",
           "arena   4000 mixed 8..512B", a2 / N_MIXED, m2 / N_MIXED, m2 / a2);

    double a3 = best(arena_touch), m3 = best(malloc_touch);
    printf("%-28s %12.2f %12.2f %8.2fx\n",
           "arena   1000 x 64B +memset", a3 / N_SMALL, m3 / N_SMALL, m3 / a3);

    double q1 = best(amalloc_small), z1 = best(malloc_small);
    printf("%-28s %12.2f %12.2f %8.2fx\n",
           "malloc  1000 x 64B", q1 / N_SMALL, z1 / N_SMALL, z1 / q1);

    double q2 = best(amalloc_mixed), z2 = best(malloc_mixed);
    printf("%-28s %12.2f %12.2f %8.2fx\n",
           "malloc  4000 mixed 8..512B", q2 / N_MIXED, z2 / N_MIXED, z2 / q2);

    /* end-to-end burst: fill 2048 x 1 KiB then reclaim */
    fill_burst();
    int blocks = gcount;
    double r1 = best(arena_fill_reset), r2 = best(malloc_free_all);
    printf("%-28s %12.2f %12.2f %8.2fx\n",
           "2048 x 1KiB fill+release (us)", r1 / 1000, r2 / 1000, r2 / r1);

    printf("\narena stats: used=%zu peak=%zu remaining=%zu capacity=%zu\n",
           asm_arena_used(&A), asm_arena_peak(&A), asm_arena_remaining(&A),
           asm_arena_capacity(&A));
    printf("reset burst: %d blocks of 1 KiB in a fixed 4 MiB arena\n", blocks);
    (void)sink;
    asm_sys_munmap(fbuf, ARENA_BYTES);
    asm_sys_munmap(gbuf, 4u << 20);
    return 0;
}
