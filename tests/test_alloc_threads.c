/*==============================================================================
 * test_alloc_threads.c - many short-lived threads exercising the tcache
 *------------------------------------------------------------------------------
 * Spawns a batch of threads that each run a burst of tagged allocations, free
 * them, then call asm_alloc_flush_tcache() the way a thread-exit hook would, so
 * a finished thread does not strand its per-thread cache. The main thread
 * checks every block stayed intact (no cross-thread corruption) and reports how
 * many blocks the flushes returned.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "asmlib.h"

#define NTHREADS 32
#define ROUNDS   300
#define MAXBLK   256

typedef struct {
    long returned;
    long ops;
    int  corrupt;
} tres_t;

static void *worker(void *arg) {
    tres_t *t = arg;
    unsigned char *p[MAXBLK];
    size_t s[MAXBLK];

    for (int r = 0; r < ROUNDS; r++) {
        int n = 1 + (r % MAXBLK);
        int bad = 0;
        for (int i = 0; i < n; i++) {
            s[i] = 1 + (size_t)((r * 131 + i * 17) % 3000);
            p[i] = (unsigned char *)asm_malloc(s[i]);
            if (!p[i]) { t->corrupt = 1; break; }
            memset(p[i], (int)(unsigned char)(i | 1), s[i]);
        }
        for (int i = 0; i < n && p[i]; i++) {
            if (p[i][0] != (unsigned char)(i | 1) ||
                p[i][s[i] - 1] != (unsigned char)(i | 1)) bad = 1;
            asm_free(p[i]);
            t->ops++;
        }
        if (bad) t->corrupt = 1;
    }
    /* thread-exit hook: hand the cache back to the shared heap */
    t->returned = (long)asm_alloc_flush_tcache();
    return NULL;
}

int main(void) {
    pthread_t th[NTHREADS];
    tres_t tr[NTHREADS];
    memset(tr, 0, sizeof tr);

    for (int i = 0; i < NTHREADS; i++)
        if (pthread_create(&th[i], NULL, worker, &tr[i]) != 0) {
            printf("FAIL: pthread_create %d\n", i);
            return 1;
        }
    long corrupt = 0, ops = 0, returned = 0;
    for (int i = 0; i < NTHREADS; i++) {
        pthread_join(th[i], NULL);
        corrupt += tr[i].corrupt;
        ops += tr[i].ops;
        returned += tr[i].returned;
    }

    printf("== asm thread-churn alloc test: %d threads x %d rounds ==\n", NTHREADS, ROUNDS);
    printf("   %ld ops, %ld blocks flushed, %ld corruption reports\n", ops, returned, corrupt);
    if (corrupt) {
        printf("FAIL: corruption detected\n");
        return 1;
    }
    printf("== OK ==\n");
    return 0;
}
