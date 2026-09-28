/*==============================================================================
 * format_bench.c - asmlib formatting vs. the host snprintf
 *------------------------------------------------------------------------------
 * Times asm_snprintf and asm_u64toa against their libc equivalents on the
 * common integer/string cases. Each workload is measured best-of-N to limit
 * scheduler noise; > 1.00x means asmlib is faster.
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

#define TRIALS 9
#define ITERS  100000

typedef int (*snfn)(char *, size_t, const char *, ...);

static snfn volatile libc_snprintf = snprintf;   /* defeats builtin folding */
static char buf[128];
static volatile size_t sink;

static double now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e9 + t.tv_nsec;
}

static double best(void (*fn)(void)) {
    double b = 1e30;
    for (int i = 0; i < TRIALS; i++) {
        double a = now_ns();
        fn();
        double c = now_ns();
        if (c - a < b) b = c - a;
    }
    return b / ITERS;
}

static void w_int_libc(void)  { for (int i = 0; i < ITERS; i++) sink += libc_snprintf(buf, sizeof buf, "%d", i * 7 - 12345); }
static void w_int_asm(void)   { for (int i = 0; i < ITERS; i++) sink += asm_snprintf(buf, sizeof buf, "%d", i * 7 - 12345); }
static void w_lld_libc(void)  { for (int i = 0; i < ITERS; i++) sink += libc_snprintf(buf, sizeof buf, "%lld", (long long)i * 1234567890123LL); }
static void w_lld_asm(void)   { for (int i = 0; i < ITERS; i++) sink += asm_snprintf(buf, sizeof buf, "%lld", (long long)i * 1234567890123LL); }
static void w_hex_libc(void)  { for (int i = 0; i < ITERS; i++) sink += libc_snprintf(buf, sizeof buf, "%08x", (unsigned)i * 2654435761u); }
static void w_hex_asm(void)   { for (int i = 0; i < ITERS; i++) sink += asm_snprintf(buf, sizeof buf, "%08x", (unsigned)i * 2654435761u); }
static void w_str_libc(void)  { for (int i = 0; i < ITERS; i++) sink += libc_snprintf(buf, sizeof buf, "[%-16s]", "hello"); }
static void w_str_asm(void)   { for (int i = 0; i < ITERS; i++) sink += asm_snprintf(buf, sizeof buf, "[%-16s]", "hello"); }
static void w_mix_libc(void)  { for (int i = 0; i < ITERS; i++) sink += libc_snprintf(buf, sizeof buf, "id=%05d n=%-8s x=0x%08x", i % 1000, "bob", (unsigned)i); }
static void w_mix_asm(void)   { for (int i = 0; i < ITERS; i++) sink += asm_snprintf(buf, sizeof buf, "id=%05d n=%-8s x=0x%08x", i % 1000, "bob", (unsigned)i); }
static void w_u64_libc(void)  { for (int i = 0; i < ITERS; i++) sink += libc_snprintf(buf, sizeof buf, "%llu", 1234567890123456789ULL + (unsigned)i); }
static void w_u64_asm(void)   { for (int i = 0; i < ITERS; i++) sink += asm_u64toa(1234567890123456789ULL + (unsigned)i, buf, sizeof buf); }

struct row { const char *name; void (*libcfn)(void); void (*asmfn)(void); };

int main(void) {
    struct row rows[] = {
        { "snprintf \"%d\"",        w_int_libc, w_int_asm },
        { "snprintf \"%lld\"",      w_lld_libc, w_lld_asm },
        { "snprintf \"%08x\"",      w_hex_libc, w_hex_asm },
        { "snprintf \"[%-16s]\"",   w_str_libc, w_str_asm },
        { "snprintf mixed",         w_mix_libc, w_mix_asm },
        { "asm_u64toa (vs %llu)",   w_u64_libc, w_u64_asm },
    };
    printf("asmlib formatting vs. libc (ns/call, best of %d; >1.00x means asmlib faster)\n", TRIALS);
    printf("workload                     libc     asmlib   speedup\n");
    printf("                           ns/call    ns/call\n");
    for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        double l = best(rows[i].libcfn);
        double a = best(rows[i].asmfn);
        printf("%-24s %8.2f  %8.2f  %6.2fx\n", rows[i].name, l, a, l / a);
    }
    (void)sink;
    return 0;
}
