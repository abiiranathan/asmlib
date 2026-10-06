/*==============================================================================
 * test_sort.c - differential tests for asm_qsort/asm_bsearch
 *------------------------------------------------------------------------------
 * Sorts arrays of several element types with asm_qsort and compares the result
 * (and asm_bsearch lookups) against the host qsort/bsearch. Also checks the
 * reentrant *_r variants and the trivial n == 0 / n == 1 cases.
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

static uint64_t rng = 0x243F6A8885A308D3ULL;
static uint64_t rnd(void) {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return rng;
}

static int cmp_int(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}
static int cmp_ll(const void *a, const void *b) {
    long long x = *(const long long *)a, y = *(const long long *)b;
    return (x > y) - (x < y);
}
struct pair { int key; int tag; };
static int cmp_pair(const void *a, const void *b) {
    const struct pair *x = a, *y = b;
    return (x->key > y->key) - (x->key < y->key);
}
static int cmp_int_r(const void *a, const void *b, void *arg) {
    int off = *(int *)arg;
    int x = *(const int *)a + off, y = *(const int *)b + off;
    return (x > y) - (x < y);
}

static void test_qsort_bsearch_int(void) {
    for (int it = 0; it < 3000; it++) {
        int n = (int)(rnd() % 300);
        int *a = malloc((size_t)n * sizeof(int) + 1);
        int *b = malloc((size_t)n * sizeof(int) + 1);
        for (int i = 0; i < n; i++) { a[i] = (int)(rnd() % 50) - 25; b[i] = a[i]; }
        asm_qsort(a, (size_t)n, sizeof(int), cmp_int);
        qsort(b, (size_t)n, sizeof(int), cmp_int);
        CHECK(n == 0 || memcmp(a, b, (size_t)n * sizeof(int)) == 0, "qsort int");
        for (int i = 1; i < n; i++) CHECK(a[i - 1] <= a[i], "qsort ordered");
        for (int k = -30; k <= 30; k++) {
            int key = k;
            int *ra = asm_bsearch(&key, a, (size_t)n, sizeof(int), cmp_int);
            int *rb = bsearch(&key, b, (size_t)n, sizeof(int), cmp_int);
            CHECK((ra == NULL) == (rb == NULL), "bsearch found");
            if (ra) CHECK(*ra == *rb, "bsearch value");
        }
        free(a); free(b);
    }
}

static void test_qsort_ll(void) {
    for (int it = 0; it < 500; it++) {
        int n = (int)(rnd() % 100);
        long long *a = malloc((size_t)n * sizeof(long long) + 1);
        long long *b = malloc((size_t)n * sizeof(long long) + 1);
        for (int i = 0; i < n; i++) {
            a[i] = (long long)(rnd() * 2654435761u);
            b[i] = a[i];
        }
        asm_qsort(a, (size_t)n, sizeof(long long), cmp_ll);
        qsort(b, (size_t)n, sizeof(long long), cmp_ll);
        CHECK(n == 0 || memcmp(a, b, (size_t)n * sizeof(long long)) == 0, "qsort long long");
        free(a); free(b);
    }
}

static void test_qsort_struct(void) {
    for (int it = 0; it < 500; it++) {
        int n = (int)(rnd() % 200);
        struct pair *a = malloc((size_t)n * sizeof(struct pair) + 1);
        struct pair *b = malloc((size_t)n * sizeof(struct pair) + 1);
        for (int i = 0; i < n; i++) {
            a[i].key = (int)(rnd() % 30); a[i].tag = i; b[i] = a[i];
        }
        asm_qsort(a, (size_t)n, sizeof(struct pair), cmp_pair);
        qsort(b, (size_t)n, sizeof(struct pair), cmp_pair);
        for (int i = 0; i < n; i++) CHECK(a[i].key == b[i].key, "qsort struct key");
        free(a); free(b);
    }
}

static void test_qsort_r(void) {
    for (int it = 0; it < 1000; it++) {
        int n = (int)(rnd() % 100);
        int off = (int)(rnd() % 10);
        int *a = malloc((size_t)n * sizeof(int) + 1);
        int *b = malloc((size_t)n * sizeof(int) + 1);
        for (int i = 0; i < n; i++) { a[i] = (int)(rnd() % 40); b[i] = a[i]; }
        asm_qsort_r(a, (size_t)n, sizeof(int), cmp_int_r, &off);
        qsort_r(b, (size_t)n, sizeof(int), cmp_int_r, &off);
        CHECK(n == 0 || memcmp(a, b, (size_t)n * sizeof(int)) == 0, "qsort_r");
        free(a); free(b);
    }
}

static void test_edge(void) {
    int one = 7;
    asm_qsort(&one, 1, sizeof(int), cmp_int);
    CHECK(one == 7, "qsort n=1");
    asm_qsort(&one, 0, sizeof(int), cmp_int);
    CHECK(one == 7, "qsort n=0");
    int key = 5;
    CHECK(asm_bsearch(&key, &one, 0, sizeof(int), cmp_int) == NULL, "bsearch empty");
    struct pair p[3] = { {1, 0}, {2, 0}, {3, 0} };
    int k2 = 2;
    CHECK(asm_bsearch(&k2, p, 3, sizeof(struct pair), cmp_pair) == &p[1], "bsearch struct");
    int k9 = 9;
    CHECK(asm_bsearch(&k9, p, 3, sizeof(struct pair), cmp_pair) == NULL, "bsearch miss");
}

int main(void) {
    printf("== asmlib sort/bsearch test suite ==\n");
    test_qsort_bsearch_int(); printf("   int         done\n");
    test_qsort_ll();          printf("   long long   done\n");
    test_qsort_struct();      printf("   struct      done\n");
    test_qsort_r();           printf("   qsort_r     done\n");
    test_edge();              printf("   edge        done\n");
    printf("== %lu checks, %lu failures ==\n", checks, failures);
    return failures != 0;
}
