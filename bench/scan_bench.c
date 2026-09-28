/*==============================================================================
 * scan_bench.c - asmlib sscanf vs. the host sscanf
 *------------------------------------------------------------------------------
 * Times asm_sscanf against libc sscanf on the integer/string cases it targets.
 * Best-of-N; > 1.00x means asmlib is faster.
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

typedef int (*ssfn)(const char *, const char *, ...);
static ssfn volatile libc_sscanf = sscanf;
static char sbuf[64];
static volatile size_t sink;

static double now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e9 + t.tv_nsec;
}
static double best(void (*fn)(void)) {
    double b = 1e30;
    for (int i = 0; i < TRIALS; i++) {
        double a = now_ns(); fn(); double c = now_ns();
        if (c - a < b) b = c - a;
    }
    return b / ITERS;
}

static void w_int_libc(void) { int v; for (int i = 0; i < ITERS; i++) { v = 0; sink += libc_sscanf("123456789", "%d", &v); sink += v; } }
static void w_int_asm(void)  { int v; for (int i = 0; i < ITERS; i++) { v = 0; sink += asm_sscanf("123456789", "%d", &v); sink += v; } }
static void w_lld_libc(void) { long long v; for (int i = 0; i < ITERS; i++) { v = 0; sink += libc_sscanf("1234567890123456789", "%lld", &v); sink += (size_t)v; } }
static void w_lld_asm(void)  { long long v; for (int i = 0; i < ITERS; i++) { v = 0; sink += asm_sscanf("1234567890123456789", "%lld", &v); sink += (size_t)v; } }
static void w_hex_libc(void) { unsigned v; for (int i = 0; i < ITERS; i++) { v = 0; sink += libc_sscanf("0xdeadbeef", "%x", &v); sink += v; } }
static void w_hex_asm(void)  { unsigned v; for (int i = 0; i < ITERS; i++) { v = 0; sink += asm_sscanf("0xdeadbeef", "%x", &v); sink += v; } }
static void w_str_libc(void) { for (int i = 0; i < ITERS; i++) sink += libc_sscanf("hello world", "%15s", sbuf) + strlen(sbuf); }
static void w_str_asm(void)  { for (int i = 0; i < ITERS; i++) sink += asm_sscanf("hello world", "%15s", sbuf) + strlen(sbuf); }
static void w_mix_libc(void) { int a = 0; unsigned h = 0; for (int i = 0; i < ITERS; i++) { sink += libc_sscanf("id=42 name=zed hex=feed", "id=%d name=%15s hex=%x", &a, sbuf, &h) + (size_t)a + h + strlen(sbuf); } }
static void w_mix_asm(void)  { int a = 0; unsigned h = 0; for (int i = 0; i < ITERS; i++) { sink += asm_sscanf("id=42 name=zed hex=feed", "id=%d name=%15s hex=%x", &a, sbuf, &h) + (size_t)a + h + strlen(sbuf); } }

struct row { const char *name; void (*libcfn)(void); void (*asmfn)(void); };

int main(void) {
    struct row rows[] = {
        { "sscanf \"%d\"",        w_int_libc, w_int_asm },
        { "sscanf \"%lld\"",      w_lld_libc, w_lld_asm },
        { "sscanf \"%x\"",        w_hex_libc, w_hex_asm },
        { "sscanf \"%15s\"",      w_str_libc, w_str_asm },
        { "sscanf mixed",         w_mix_libc, w_mix_asm },
    };
    printf("asmlib sscanf vs. libc (ns/call, best of %d; >1.00x means asmlib faster)\n", TRIALS);
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
