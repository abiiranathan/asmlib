/*==============================================================================
 * perfbench.c - one phase per invocation so `perf` attribution is unambiguous
 *------------------------------------------------------------------------------
 * Usage: ./perfbench <name> [reps]
 * Phases: memcpy memcpy128 memset memcmp strlen memchr strchr strcmp
 *         memmem arena_alloc malloc_free memmove memset8
 *============================================================================*/

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include "asmlib.h"

static uint64_t xorshift(void) {
    static uint64_t st = 0x123456789abcdef0ULL;
    st ^= st << 13; st ^= st >> 7; st ^= st << 17;
    return st;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: perfbench <name> [reps]\n"); return 2; }
    const char *name = argv[1];
    long reps = argc > 2 ? atol(argv[2]) : 100000;

    enum { SIZE = 1 << 20 };
    unsigned char *a = malloc(SIZE + 64);
    unsigned char *b = malloc(SIZE + 64);
    for (int i = 0; i < SIZE; i++) a[i] = b[i] = (unsigned char)(i * 31 + 7);

    char *s1 = malloc(1024 * 1024 * 2);
    for (int i = 0; i < 2 * 1024 * 1024 - 1; i++) s1[i] = (char)('a' + (i % 26));
    s1[2 * 1024 * 1024 - 1] = 0;

    size_t snk = 0;
    (void)reps;

    if (!strcmp(name, "memcpy")) {
        for (long i = 0; i < reps; i++) { asm_memcpy(b, a, SIZE); snk += b[i & 63]; }
    } else if (!strcmp(name, "memcpy128")) {
        for (long i = 0; i < reps; i++) { asm_memcpy(b, a, 128); snk += b[0]; }
    } else if (!strcmp(name, "memcpy1k")) {
        for (long i = 0; i < reps; i++) { asm_memcpy(b, a, 1024); snk += b[0]; }
    } else if (!strcmp(name, "memset")) {
        for (long i = 0; i < reps; i++) { asm_memset(b, 0xA5, SIZE); snk += b[i & 63]; }
    } else if (!strcmp(name, "memset1k")) {
        for (long i = 0; i < reps; i++) { asm_memset(b, 0xA5, 1024); snk += b[0]; }
    } else if (!strcmp(name, "memcmp")) {
        for (long i = 0; i < reps; i++) { snk += (size_t)asm_memcmp(a, b, SIZE); }
    } else if (!strcmp(name, "strlen")) {
        for (long i = 0; i < reps; i++) { snk += asm_strlen(s1); }
    } else if (!strcmp(name, "strchr")) {
        for (long i = 0; i < reps; i++) { snk += (size_t)asm_strchr(s1, 'z'); }
    } else if (!strcmp(name, "memchr")) {
        for (long i = 0; i < reps; i++) { snk += (size_t)asm_memchr(a, 'z', SIZE); }
    } else if (!strcmp(name, "memchr_scan")) {
        for (long i = 0; i < reps; i++) { snk += (size_t)asm_memchr(a, 0x7E, SIZE); }
    } else if (!strcmp(name, "strchr_scan")) {
        for (long i = 0; i < reps; i++) { snk += (size_t)asm_strchr(s1, '\0'); }
    } else if (!strcmp(name, "strncasecmp")) {
        char *t = malloc(1024 * 1024);
        for (int i = 0; i < 1024 * 1024; i++) t[i] = (char)('A' + (i % 26));
        for (long i = 0; i < reps; i++) { snk += (size_t)asm_strncasecmp(s1, t, 1024 * 1024); }
    } else if (!strcmp(name, "strcmp")) {
        for (long i = 0; i < reps; i++) { snk += (size_t)asm_strcmp(s1, s1); }
    } else if (!strcmp(name, "memmem")) {
        for (long i = 0; i < reps; i++) { snk += (size_t)asm_memmem(a, SIZE, "zzz", 3); }
    } else if (!strcmp(name, "arena_alloc")) {
        asm_arena ar;
        void *abuf = malloc(64u << 20);
        asm_arena_init(&ar, abuf, 64u << 20);
        for (long i = 0; i < reps; i++) {
            void *p = asm_arena_alloc(&ar, 64);
            snk += (size_t)((char *)p)[0];
        }
    } else if (!strcmp(name, "malloc_free")) {
        for (long i = 0; i < reps; i++) {
            void *p = asm_malloc(64);
            asm_free(p);
            snk += (size_t)p;
        }
    } else {
        fprintf(stderr, "unknown phase '%s'\n", name);
        return 2;
    }
    (void)snk;
    (void)xorshift;
    printf("%-12s done sink=%zu\n", name, (size_t)snk);
    return 0;
}
/* appended: no-match phases for scan-heavy routines */
