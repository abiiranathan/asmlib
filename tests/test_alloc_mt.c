/*==============================================================================
 * test_alloc_mt.c - multithreaded stress test for the asm malloc-style heap
 *------------------------------------------------------------------------------
 * Spawns N threads (default 8) that concurrently hammer asm_malloc,
 * asm_calloc, asm_realloc, asm_reallocarray, asm_aligned_alloc and asm_free.
 * Every block is tagged across its payload when it is handed out and the tag
 * is re-verified before each free/realloc, so any double hand-out, overlap or
 * lost update from a race is caught. Alignment and usable size are checked
 * too. A second "hot" phase has every thread looping over the same few size
 * classes at once to maximise lock contention.
 *
 * usage: test_alloc_mt [threads [iterations]]
 * env:   MT_THREADS=n MT_ITERS=n      (overridden by argv)
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>

#include "asmlib.h"

#define MAX_SLOTS 2048
#define HOT_BLOCKS 64

typedef struct {
    unsigned char *p;
    size_t sz;
    size_t align;
    unsigned char tag;
    int live;
} rec_t;

typedef struct {
    int id;
    long iters;
    long corrupt;
    long ops;
} targ_t;

static pthread_barrier_t g_start;

/* ---- thread-local xorshift PRNG ------------------------------------------- */
static inline uint64_t xrand(uint64_t *s) {
    uint64_t x = *s;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return *s = x;
}

/* Reject a block whose tag bytes (first/last of the requested payload) were
 * scribbled on by somebody else. */
static inline int tag_bad(const rec_t *r) {
    return r->p[0] != r->tag || r->p[r->sz - 1] != r->tag;
}

/*------------------------------------------------------------------------------
 * Randomised alloc/free/realloc phase
 *----------------------------------------------------------------------------*/
static void run_random(targ_t *t) {
    rec_t rec[MAX_SLOTS];                    /* per-thread: never shared */
    int fstack[MAX_SLOTS];
    int nfree = 0, nslot = 0;
    uint64_t s = 0x9E3779B97F4A7C15ULL * (uint64_t)(t->id + 1) + 0x1234567ULL;

    for (long it = 0; it < t->iters; it++) {
        long a = (long)(xrand(&s) % 100);
        if (nslot == 0 || a < 45) {
            /* ---- allocate ---- */
            size_t sz = 1 + (size_t)(xrand(&s) % 8000);
            int idx;
            if (nfree > 0) idx = fstack[--nfree];
            else if (nslot < MAX_SLOTS) idx = nslot++;
            else continue;                       /* table full: skip */
            unsigned char tag = (unsigned char)(xrand(&s) | 1);
            size_t align = 16;
            unsigned char *p = NULL;
            int kind = (int)(xrand(&s) % 100);

            if (kind < 60) {
                p = asm_malloc(sz);
            } else if (kind < 75) {
                size_t cnt = 1 + (size_t)(xrand(&s) % 8);
                size_t esz = 1 + (size_t)(xrand(&s) % 8000);
                sz = cnt * esz;
                p = asm_calloc(cnt, esz);
                if (p && (p[0] != 0 || p[sz - 1] != 0)) { t->corrupt++; return; }
            } else if (kind < 90) {
                align = (size_t)1 << (5 + (xrand(&s) % 8));   /* 32 .. 4096 */
                p = asm_aligned_alloc(align, sz);
            } else {
                size_t cnt = 1 + (size_t)(xrand(&s) % 16);
                size_t esz = 1 + (size_t)(xrand(&s) % 8000);
                sz = cnt * esz;
                p = asm_reallocarray(NULL, cnt, esz);
            }
            if (!p) { t->corrupt++; return; }
            if (((uintptr_t)p & (align - 1)) != 0) { t->corrupt++; return; }
            if (asm_malloc_usable_size(p) < sz) { t->corrupt++; return; }
            memset(p, tag, sz);
            rec[idx].p = p;
            rec[idx].sz = sz;
            rec[idx].align = align;
            rec[idx].tag = tag;
            rec[idx].live = 1;
        } else if (a < 75) {
            /* ---- free ---- */
            int idx = (int)(xrand(&s) % (unsigned)nslot);
            if (!rec[idx].live) continue;
            if (tag_bad(&rec[idx])) { t->corrupt++; return; }
            asm_free(rec[idx].p);
            rec[idx].live = 0;
            fstack[nfree++] = idx;
        } else {
            /* ---- realloc / reallocarray ---- */
            int idx = (int)(xrand(&s) % (unsigned)nslot);
            if (!rec[idx].live) continue;
            size_t oldsz = rec[idx].sz;
            unsigned char oldtag = rec[idx].tag;
            if (tag_bad(&rec[idx])) { t->corrupt++; return; }

            size_t newsz = 1 + (size_t)(xrand(&s) % 8000);
            unsigned char *np;
            if (xrand(&s) & 1) {
                np = asm_realloc(rec[idx].p, newsz);
            } else {
                size_t cnt = 1 + (size_t)(xrand(&s) % 8);
                size_t esz = 1 + (size_t)(xrand(&s) % 8000);
                newsz = cnt * esz;
                np = asm_reallocarray(rec[idx].p, cnt, esz);
            }
            if (!np) { t->corrupt++; return; }
            if (((uintptr_t)np & 15) != 0) { t->corrupt++; return; }
            size_t keep = oldsz < newsz ? oldsz : newsz;
            if (np[0] != oldtag || np[keep - 1] != oldtag) { t->corrupt++; return; }
            unsigned char tag = (unsigned char)(xrand(&s) | 1);
            memset(np, tag, newsz);
            rec[idx].p = np;
            rec[idx].sz = newsz;
            rec[idx].tag = tag;
            rec[idx].live = 1;
        }
        t->ops++;
    }

    /* free everything still live, re-verifying first */
    for (int i = 0; i < nslot; i++) {
        if (!rec[i].live) continue;
        if (tag_bad(&rec[i])) t->corrupt++;
        asm_free(rec[i].p);
        rec[i].live = 0;
    }
}

/*------------------------------------------------------------------------------
 * Contended hot loop: all threads cycle the same few size classes
 *----------------------------------------------------------------------------*/
static void run_hot(targ_t *t) {
    static const size_t classes[] = {16, 48, 128, 512, 1024, 4096};
    const size_t nclasses = sizeof classes / sizeof classes[0];
    unsigned char *hp[HOT_BLOCKS];
    unsigned char tags[HOT_BLOCKS];
    long iters = t->iters / 400 + 400;       /* keep the run-time bounded */

    for (long it = 0; it < iters; it++) {
        size_t sz = classes[(size_t)(it % (long)nclasses)];
        int i;
        for (i = 0; i < HOT_BLOCKS; i++) {
            hp[i] = asm_malloc(sz);
            if (!hp[i]) { t->corrupt++; goto cleanup; }
            if (((uintptr_t)hp[i] & 15) != 0) { t->corrupt++; goto cleanup; }
            if (asm_malloc_usable_size(hp[i]) < sz) { t->corrupt++; goto cleanup; }
            tags[i] = (unsigned char)((it * 131 + i) | 1);
            memset(hp[i], tags[i], sz);
        }
        for (i = 0; i < HOT_BLOCKS; i++) {
            if (hp[i][0] != tags[i] || hp[i][sz - 1] != tags[i]) {
                t->corrupt++;
                goto cleanup;
            }
        }
cleanup:
        while (i-- > 0) asm_free(hp[i]);
        t->ops += HOT_BLOCKS;
    }
}

/*------------------------------------------------------------------------------
 * Cross-thread hand-off: each thread allocates a slice, then frees the slice
 * owned by another thread. A block freed on a thread other than the one that
 * allocated it must land in the freeing thread's tcache (or the global heap)
 * without corruption.
 *----------------------------------------------------------------------------*/
#define XT_N 4096
static unsigned char *xt_p[XT_N];
static size_t         xt_sz[XT_N];
static unsigned char  xt_tag[XT_N];
static long           xt_bad;

static void run_cross(int nthreads, int id) {
    int per = XT_N / nthreads;
    int lo = id * per;
    int hi = (id == nthreads - 1) ? XT_N : lo + per;

    for (int i = lo; i < hi; i++) {
        size_t s = 1 + (size_t)(i % 1500);
        unsigned char t = (unsigned char)(i | 1);
        xt_p[i] = asm_malloc(s);
        xt_sz[i] = s; xt_tag[i] = t;
        if (xt_p[i]) memset(xt_p[i], t, s);
        else __atomic_store_n(&xt_bad, 1, __ATOMIC_RELAXED);
    }
    pthread_barrier_wait(&g_start);      /* wait until every slice is filled */

    int nid = (id + 1) % nthreads;
    int nlo = nid * per;
    int nhi = (nid == nthreads - 1) ? XT_N : nlo + per;
    for (int i = nlo; i < nhi; i++) {
        if (!xt_p[i]) continue;
        if (xt_p[i][0] != xt_tag[i] || xt_p[i][xt_sz[i] - 1] != xt_tag[i])
            __atomic_store_n(&xt_bad, 1, __ATOMIC_RELAXED);
        asm_free(xt_p[i]);
    }
}

static int g_nthreads = 1;

static void *worker(void *arg) {
    targ_t *t = arg;
    pthread_barrier_wait(&g_start);          /* start all threads together */
    run_random(t);
    run_hot(t);
    run_cross(g_nthreads, t->id);
    return NULL;
}

int main(int argc, char **argv) {
    long nthreads = 8, iters = 200000;

    const char *e = getenv("MT_THREADS");
    if (e) nthreads = strtol(e, NULL, 10);
    e = getenv("MT_ITERS");
    if (e) iters = strtol(e, NULL, 10);
    if (argc > 1) nthreads = strtol(argv[1], NULL, 10);
    if (argc > 2) iters = strtol(argv[2], NULL, 10);
    if (nthreads < 1) nthreads = 1;
    if (nthreads > 256) nthreads = 256;
    if (iters < 1) iters = 1;

    printf("== asm multithreaded alloc test: %ld threads x %ld iters ==\n",
           nthreads, iters);

    pthread_t *tid = calloc((size_t)nthreads, sizeof *tid);
    targ_t *args = calloc((size_t)nthreads, sizeof *args);
    if (!tid || !args) { printf("FAIL: setup\n"); return 1; }

    if (pthread_barrier_init(&g_start, NULL, (unsigned)nthreads) != 0) {
        printf("FAIL: barrier init\n");
        return 1;
    }
    g_nthreads = (int)nthreads;
    for (long i = 0; i < nthreads; i++) {
        args[i].id = (int)i;
        args[i].iters = iters;
        if (pthread_create(&tid[i], NULL, worker, &args[i]) != 0) {
            printf("FAIL: pthread_create %ld\n", i);
            return 1;
        }
    }

    long corrupt = 0, ops = 0;
    for (long i = 0; i < nthreads; i++) {
        pthread_join(tid[i], NULL);
        corrupt += args[i].corrupt;
        ops += args[i].ops;
    }
    corrupt += __atomic_load_n(&xt_bad, __ATOMIC_RELAXED);
    pthread_barrier_destroy(&g_start);
    free(tid);
    free(args);

    printf("   %ld operations, %ld corruption reports\n", ops, corrupt);
    if (corrupt) {
        printf("FAIL: corruption detected\n");
        return 1;
    }
    printf("== OK ==\n");
    return 0;
}
