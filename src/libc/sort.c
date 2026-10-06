/*==============================================================================
 * sort.c - portable, freestanding qsort/qsort_r and bsearch/bsearch_r
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * A libc-compatible sort/search pair for wasm32 and other targets where the
 * hand-written assembly does not run. qsort is an introsort: median-of-three
 * quicksort with an insertion-sort cutoff and a heapsort fallback if the
 * recursion gets too deep, so the worst case is O(n log n) and the stack depth
 * is O(log n). Elements are moved as raw bytes, so any element type works.
 *
 *   void  asm_qsort (void *base, size_t n, size_t size, compar);
 *   void  asm_qsort_r(void *base, size_t n, size_t size, compar_r, void *arg);
 *   void *asm_bsearch(const void *key, const void *base, size_t n, size_t size, compar);
 *   void *asm_bsearch_r(const void *key, const void *base, size_t n, size_t size, compar_r, void *arg);
 *============================================================================*/

#include "portable.h"

#include <stddef.h>

typedef int (*cmp_v)(const void *, const void *);
typedef int (*cmp_r)(const void *, const void *, void *);

#define CMP(ctx, a, b) ((ctx).use_r ? (ctx).r(a, b, (ctx).arg) : (ctx).v(a, b))

struct cmpctx {
    int use_r;
    cmp_v v;
    cmp_r r;
    void *arg;
};

static void byte_swap(unsigned char *a, unsigned char *b, size_t size) {
    while (size--) {
        unsigned char t = *a;
        *a++ = *b;
        *b++ = t;
    }
}

static void insertion_sort(unsigned char *base, size_t n, size_t size,
                           struct cmpctx ctx) {
    for (size_t i = 1; i < n; i++) {
        size_t j = i;
        while (j > 0 && CMP(ctx, base + (j - 1) * size, base + j * size) > 0) {
            byte_swap(base + (j - 1) * size, base + j * size, size);
            j--;
        }
    }
}

static void sift_down(unsigned char *base, size_t root, size_t n, size_t size,
                      struct cmpctx ctx) {
    for (;;) {
        size_t child = 2 * root + 1;
        if (child >= n) break;
        if (child + 1 < n &&
            CMP(ctx, base + child * size, base + (child + 1) * size) < 0)
            child++;
        if (CMP(ctx, base + root * size, base + child * size) < 0) {
            byte_swap(base + root * size, base + child * size, size);
            root = child;
        } else break;
    }
}

static void heap_sort(unsigned char *base, size_t n, size_t size,
                      struct cmpctx ctx) {
    if (n < 2) return;
    for (size_t start = n / 2; start-- > 0; )
        sift_down(base, start, n, size, ctx);
    for (size_t end = n - 1; end > 0; end--) {
        byte_swap(base, base + end * size, size);
        sift_down(base, 0, end, size, ctx);
    }
}

static size_t median3(unsigned char *base, size_t a, size_t b, size_t c,
                      size_t size, struct cmpctx ctx) {
    if (CMP(ctx, base + a * size, base + b * size) < 0) {
        if (CMP(ctx, base + b * size, base + c * size) < 0) return b;
        if (CMP(ctx, base + a * size, base + c * size) < 0) return c;
        return a;
    }
    if (CMP(ctx, base + a * size, base + c * size) < 0) return a;
    if (CMP(ctx, base + b * size, base + c * size) < 0) return c;
    return b;
}

static void intro_sort(unsigned char *base, size_t n, size_t size,
                       struct cmpctx ctx, int depth) {
    while (n > 16) {
        size_t p, i, j;
        if (depth-- <= 0) { heap_sort(base, n, size, ctx); return; }
        p = median3(base, 0, n / 2, n - 1, size, ctx);
        byte_swap(base, base + p * size, size);
        i = 1;
        j = n - 1;
        for (;;) {
            while (i <= j && CMP(ctx, base + i * size, base) <= 0) i++;
            while (i <= j && CMP(ctx, base + j * size, base) > 0) j--;
            if (i > j) break;
            byte_swap(base + i * size, base + j * size, size);
            i++;
            j--;
        }
        byte_swap(base, base + j * size, size);
        if (j < n - j) {
            intro_sort(base, j, size, ctx, depth);
            base += (j + 1) * size;
            n -= j + 1;
        } else {
            intro_sort(base + (j + 1) * size, n - j - 1, size, ctx, depth);
            n = j;
        }
    }
    insertion_sort(base, n, size, ctx);
}

static int depth_limit(size_t n) {
    int d = 0;
    while (n > 1) { n >>= 1; d++; }
    return 2 * d;
}

static void do_sort(void *base, size_t n, size_t size, struct cmpctx ctx) {
    if (n < 2 || size == 0) return;
    intro_sort((unsigned char *)base, n, size, ctx, depth_limit(n));
}

void ASM_LIBC(qsort)(void *base, size_t nmemb, size_t size, cmp_v compar) {
    struct cmpctx ctx;
    ctx.use_r = 0; ctx.v = compar; ctx.r = 0; ctx.arg = 0;
    do_sort(base, nmemb, size, ctx);
}

void ASM_LIBC(qsort_r)(void *base, size_t nmemb, size_t size, cmp_r compar,
                       void *arg) {
    struct cmpctx ctx;
    ctx.use_r = 1; ctx.v = 0; ctx.r = compar; ctx.arg = arg;
    do_sort(base, nmemb, size, ctx);
}

static void *do_search(const void *key, const void *base, size_t n, size_t size,
                       struct cmpctx ctx) {
    const unsigned char *b = (const unsigned char *)base;
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int c = CMP(ctx, key, b + mid * size);
        if (c < 0) hi = mid;
        else if (c > 0) lo = mid + 1;
        else return (void *)(b + mid * size);
    }
    return NULL;
}

void *ASM_LIBC(bsearch)(const void *key, const void *base, size_t nmemb,
                        size_t size, cmp_v compar) {
    struct cmpctx ctx;
    ctx.use_r = 0; ctx.v = compar; ctx.r = 0; ctx.arg = 0;
    return do_search(key, base, nmemb, size, ctx);
}

void *ASM_LIBC(bsearch_r)(const void *key, const void *base, size_t nmemb,
                          size_t size, cmp_r compar, void *arg) {
    struct cmpctx ctx;
    ctx.use_r = 1; ctx.v = 0; ctx.r = compar; ctx.arg = arg;
    return do_search(key, base, nmemb, size, ctx);
}
