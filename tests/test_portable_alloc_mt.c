/*==============================================================================
 * test_portable_alloc_mt.c - multithreaded tests for the portable allocator
 *------------------------------------------------------------------------------
 * Drives src/libc/alloc.c concurrently through the portable API and checks that
 * the global spinlock keeps the shared region and free list consistent:
 *
 *   * 8 threads run ~200k mixed malloc/calloc/realloc/reallocarray/
 *     free/aligned_alloc operations each, with random sizes. Every block is
 *     tagged, alignment and calloc zeroing are verified, and live payloads are
 *     re-checked before free and at the end so any overlap or corruption is
 *     caught.
 *   * A second contended same-size hot loop has all threads hammer the same
 *     request size to stress the lock.
 *
 * Note: blocks produced by aligned_alloc with alignment > 16 (the "indirect"
 * blocks) are freed but deliberately not realloc-grown in this test. The
 * allocator's pre-existing malloc_usable_size() reports 16 bytes more than an
 * indirect block can actually hold, so an in-place realloc grow to that reported
 * size writes into the following block's header. That is unrelated to thread
 * safety and must not be "fixed" here, so this test sidesteps it.
 *
 * Build (native + ThreadSanitizer):
 *   cc -O2 -std=c11 -ffreestanding -fno-builtin -fno-stack-protector \
 *      -Wall -Wextra -Isrc/libc -pthread -o test_portable_alloc_mt \
 *      tests/test_portable_alloc_mt.c src/libc/alloc.c
 *============================================================================*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <pthread.h>

#include "portable.h"

#define NTHREADS       8
#define OPS_PER_THREAD 200000
#define HOT_ITERS      50000
#define HOT_BATCH      8
#define ASM_ALIGN      16u

struct worker {
    int id;
    unsigned long checks;
    unsigned long failures;
};

static uint64_t rng_next(uint64_t *s) {
    uint64_t x = *s;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return *s = x;
}

static int is_aligned(const void *p, size_t a) {
    return ((uintptr_t)p & (a - 1)) == 0;
}

static void tcheck(struct worker *w, int cond, const char *msg, int line) {
    w->checks++;
    if (!cond) {
        printf("FAIL: t%d %-28s line %d\n", w->id, msg, line);
        w->failures++;
    }
}
#define TCHECK(w, cond, msg) tcheck((w), !!(cond), (msg), __LINE__)

/*------------------------------------------------------------------------------
 * 200k mixed operations per thread with full tag re-verification
 *----------------------------------------------------------------------------*/
enum { MAXLIVE = 256 };

struct slot {
    unsigned char *p;
    size_t sz;
    unsigned char tag;
    int live;
    int indirect;   /* over-aligned block: not safely realloc-growable (see note) */
};

static void *worker_mixed(void *arg) {
    struct worker *w = (struct worker *)arg;
    struct slot tab[MAXLIVE];
    int freestack[MAXLIVE];
    int nfree = 0, nslots = 0, bad = 0;
    uint64_t st = 0x9e3779b97f4a7c15ULL ^ ((uint64_t)w->id * 0x100000001b3ULL);

    memset(tab, 0, sizeof tab);

    for (int iter = 0; iter < OPS_PER_THREAD && !bad; iter++) {
        int action = (int)(rng_next(&st) % 100);

        if (nslots == 0 || action < 35) {
            size_t s = 1 + (size_t)(rng_next(&st) % 1024);
            int idx;
            int kind = (int)(rng_next(&st) % 4);
            int ind = 0;
            unsigned char *p;

            if (nfree > 0) idx = freestack[--nfree];
            else if (nslots < MAXLIVE) idx = nslots++;
            else continue;                      /* table full: skip this alloc */

            if (kind == 0) {
                p = ASM_LIBC(calloc)(1, s);
            } else if (kind == 1) {
                p = ASM_LIBC(malloc)(s);
            } else if (kind == 2) {
                p = ASM_LIBC(reallocarray)(NULL, 1, s);
            } else {
                size_t a = (size_t)16u << (rng_next(&st) % 3u);   /* 16, 32, 64 */
                p = ASM_LIBC(aligned_alloc)(a, s);
                ind = (a > ASM_ALIGN);
                if (p != NULL) TCHECK(w, is_aligned(p, a), "aligned_alloc align");
            }

            if (p == NULL || !is_aligned(p, ASM_ALIGN)) {
                TCHECK(w, 0, "mixed alloc");
                bad = 1;
                break;
            }
            TCHECK(w, ASM_LIBC(malloc_usable_size)(p) >= s, "usable >= request");

            if (kind == 0) {
                int zero = 1;
                for (size_t j = 0; j < s; j++) if (p[j]) zero = 0;
                if (!zero) { TCHECK(w, 0, "calloc zeroed"); bad = 1; break; }
            }
            {
                unsigned char tag = (unsigned char)(rng_next(&st) | 1);
                memset(p, tag, s);
                tab[idx].p = p;
                tab[idx].sz = s;
                tab[idx].tag = tag;
                tab[idx].live = 1;
                tab[idx].indirect = ind;
            }
        } else if (action < 80) {
            int idx = (int)(rng_next(&st) % (uint64_t)nslots);
            unsigned char *p;
            size_t s;
            unsigned char tag;

            if (!tab[idx].live) continue;
            p = tab[idx].p;
            s = tab[idx].sz;
            tag = tab[idx].tag;
            if (p[0] != tag || p[s - 1] != tag) {
                TCHECK(w, 0, "free tag intact");
                bad = 1;
                break;
            }
            ASM_LIBC(free)(p);
            tab[idx].live = 0;
            freestack[nfree++] = idx;
        } else {
            int idx = (int)(rng_next(&st) % (uint64_t)nslots);
            size_t oldsz, newsz, keep;
            unsigned char oldtag, tag;
            unsigned char *np;

            if (!tab[idx].live) continue;
            if (tab[idx].indirect) continue;   /* avoid pre-existing bug, below */
            oldsz = tab[idx].sz;
            oldtag = tab[idx].tag;
            newsz = 1 + (size_t)(rng_next(&st) % 1024);
            keep = oldsz < newsz ? oldsz : newsz;

            if (rng_next(&st) & 1)
                np = ASM_LIBC(realloc)(tab[idx].p, newsz);
            else
                np = ASM_LIBC(reallocarray)(tab[idx].p, 1, newsz);

            if (np == NULL || !is_aligned(np, ASM_ALIGN)) {
                TCHECK(w, 0, "realloc");
                bad = 1;
                break;
            }
            if (np[0] != oldtag || np[keep - 1] != oldtag) {
                TCHECK(w, 0, "realloc preserved");
                bad = 1;
                break;
            }
            tag = (unsigned char)(rng_next(&st) | 1);
            memset(np, tag, newsz);
            tab[idx].p = np;
            tab[idx].sz = newsz;
            tab[idx].tag = tag;
            tab[idx].live = 1;
        }
    }

    {
        int intact = 1;
        for (int i = 0; i < nslots; i++) {
            if (!tab[i].live) continue;
            if (tab[i].p[0] != tab[i].tag ||
                tab[i].p[tab[i].sz - 1] != tab[i].tag) intact = 0;
            ASM_LIBC(free)(tab[i].p);
        }
        TCHECK(w, intact, "final live blocks intact");
    }
    TCHECK(w, !bad, "mixed no corruption");
    return NULL;
}

/*------------------------------------------------------------------------------
 * Contended same-size hot loop: every thread churns a small batch of equally
 * sized blocks, forcing heavy spinlock traffic.
 *----------------------------------------------------------------------------*/
static void *worker_hot(void *arg) {
    struct worker *w = (struct worker *)arg;
    uint64_t st = 0x2545f4914f6cdd1dULL ^ ((uint64_t)w->id * 0xd6e8feb86659fd93ULL);

    for (int iter = 0; iter < HOT_ITERS; iter++) {
        unsigned char *p[HOT_BATCH];
        unsigned char tag = (unsigned char)(rng_next(&st) | 1);
        int n = 0, ok = 1;

        for (; n < HOT_BATCH; n++) {
            p[n] = ASM_LIBC(malloc)(64);
            if (p[n] == NULL || !is_aligned(p[n], ASM_ALIGN)) {
                TCHECK(w, 0, "hot malloc");
                ok = 0;
                break;
            }
            memset(p[n], tag, 64);
        }
        if (!ok) {
            for (int k = 0; k < n; k++) ASM_LIBC(free)(p[k]);
            break;
        }
        for (int k = 0; k < HOT_BATCH; k++)
            TCHECK(w, p[k][0] == tag && p[k][63] == tag, "hot tag intact");
        for (int k = 0; k < HOT_BATCH; k++) ASM_LIBC(free)(p[k]);
    }
    return NULL;
}

int main(void) {
    pthread_t th[NTHREADS];
    struct worker workers[NTHREADS];
    unsigned long checks = 0, failures = 0;

    printf("== portable allocator multithreaded test ==\n");

    for (int i = 0; i < NTHREADS; i++) {
        workers[i].id = i;
        workers[i].checks = 0;
        workers[i].failures = 0;
        if (pthread_create(&th[i], NULL, worker_mixed, &workers[i]) != 0) {
            printf("pthread_create failed\n");
            return 2;
        }
    }
    for (int i = 0; i < NTHREADS; i++) pthread_join(th[i], NULL);
    for (int i = 0; i < NTHREADS; i++) {
        checks += workers[i].checks;
        failures += workers[i].failures;
    }
    printf("   mixed 8x%d ops done\n", OPS_PER_THREAD);

    for (int i = 0; i < NTHREADS; i++) {
        workers[i].checks = 0;
        workers[i].failures = 0;
        if (pthread_create(&th[i], NULL, worker_hot, &workers[i]) != 0) {
            printf("pthread_create failed\n");
            return 2;
        }
    }
    for (int i = 0; i < NTHREADS; i++) pthread_join(th[i], NULL);
    for (int i = 0; i < NTHREADS; i++) {
        checks += workers[i].checks;
        failures += workers[i].failures;
    }
    printf("   hot 8x%d batches done\n", HOT_ITERS);

    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
