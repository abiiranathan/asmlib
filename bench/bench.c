/*==============================================================================
 * bench.c - micro-benchmark: asmlib vs. libc for the hot routines
 *------------------------------------------------------------------------------
 * Uses volatile function pointers so the compiler cannot replace libc calls
 * with builtins or optimise the loops away. Reports nanoseconds per call and
 * the throughput for memory operations.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "asmlib.h"

typedef void *(*mfn)(void *, const void *, size_t);
typedef void *(*mfn2)(void *, int, size_t);
typedef int   (*cfn)(const void *, const void *, size_t);
typedef size_t(*sfn)(const char *);
typedef char *(*subfn)(const char *, const char *);
typedef void *(*chfn)(const void *, int, size_t);

static mfn   volatile libc_memcpy  = memcpy;
static mfn   volatile libc_memmove = memmove;
static mfn2  volatile libc_memset  = memset;
static cfn   volatile libc_memcmp  = memcmp;
static sfn   volatile libc_strlen  = strlen;
static subfn volatile libc_strstr  = strstr;
static chfn  volatile libc_memchr  = memchr;

static double now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

static volatile size_t sink;   /* prevents dead-code elimination */

#define ITERS 20000

static void bench_mem(size_t size) {
    unsigned char *a = aligned_alloc(64, size + 64);
    unsigned char *b = aligned_alloc(64, size + 64);
    memset(a, 0xC3, size + 64);
    memset(b, 0x5A, size + 64);
    double t0, t1;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) { libc_memcpy(b, a, size); sink += b[i & 63]; }
    t1 = now_ns();
    double libc_ns = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) { asm_memcpy(b, a, size); sink += b[i & 63]; }
    t1 = now_ns();
    double asm_ns = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) { libc_memset(b, 0x5A, size); sink += b[i & 63]; }
    t1 = now_ns();
    double libc_set = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) { asm_memset(b, 0x5A, size); sink += b[i & 63]; }
    t1 = now_ns();
    double asm_set = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) sink += libc_memcmp(a, a, size);
    t1 = now_ns();
    double libc_cmp = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) sink += asm_memcmp(a, a, size);
    t1 = now_ns();
    double asm_cmp = (t1 - t0) / ITERS;

    printf("  %8zu | memcpy %7.1f/%7.1f %5.2fx | memset %7.1f/%7.1f %5.2fx"
           " | memcmp %7.1f/%7.1f %5.2fx\n",
           size,
           libc_ns, asm_ns, libc_ns / asm_ns,
           libc_set, asm_set, libc_set / asm_set,
           libc_cmp, asm_cmp, libc_cmp / asm_cmp);
    free(a); free(b);
}

static void bench_str(size_t len) {
    char *s = malloc(len + 2);
    char *t = malloc(len + 2);
    for (size_t i = 0; i < len; i++) s[i] = (char)('a' + (i % 26));
    s[len] = 0; memcpy(t, s, len + 1);
    double t0, t1;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) sink += libc_strlen(s);
    t1 = now_ns();
    double libc_len = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) sink += asm_strlen(s);
    t1 = now_ns();
    double asm_len = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) sink += (size_t)libc_memchr(s, 'z', len);
    t1 = now_ns();
    double libc_ch = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) sink += (size_t)asm_memchr(s, 'z', len);
    t1 = now_ns();
    double asm_ch = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) sink += (size_t)libc_strstr(s, "zzz");
    t1 = now_ns();
    double libc_ss = (t1 - t0) / ITERS;

    t0 = now_ns();
    for (int i = 0; i < ITERS; i++) sink += (size_t)asm_strstr(s, "zzz");
    t1 = now_ns();
    double asm_ss = (t1 - t0) / ITERS;

    printf("  %8zu | strlen %7.1f/%7.1f %5.2fx | memchr %7.1f/%7.1f %5.2fx"
           " | strstr %8.1f/%8.1f %5.2fx\n",
           len,
           libc_len, asm_len, libc_len / asm_len,
           libc_ch, asm_ch, libc_ch / asm_ch,
           libc_ss, asm_ss, libc_ss / asm_ss);
    free(s); free(t);
}

int main(void) {
    printf("asmlib benchmark (ns/call, asm/libc and speedup; >1.00x is asm faster)\n");
    printf("CPU features: 0x%02x (AVX2/OS support: %d)\n",
           asm_cpu_features(), asm_cpu_has_avx2());
    printf("\n== memory: libc/asm ratio ==\n");
    size_t sizes[] = {8, 16, 32, 64, 128, 256, 1024, 4096, 65536, 1048576};
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++)
        bench_mem(sizes[i]);
    printf("\n== strings: libc/asm ratio ==\n");
    size_t lens[] = {8, 32, 128, 512, 4096, 65536};
    for (size_t i = 0; i < sizeof lens / sizeof lens[0]; i++)
        bench_str(lens[i]);
    (void)sink;
    return 0;
}
