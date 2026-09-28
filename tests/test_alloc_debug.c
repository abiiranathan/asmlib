/*==============================================================================
 * test_alloc_debug.c - double-free detection in the ASMLIB_ALLOC_DEBUG heap
 *------------------------------------------------------------------------------
 * Built against an allocator compiled with -DASMLIB_ALLOC_DEBUG. A double free
 * of a small block must trap (SIGILL) instead of corrupting the free list, so
 * the check runs in a forked child and the parent asserts it died by signal.
 * Normal allocation still has to work.
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <sys/resource.h>
#endif

#include "asmlib.h"

/* The trap is deliberate, so keep the dying child from writing a core dump
 * (which systemd-coredump would capture and turn into a "process crashed"
 * notification). PR_SET_DUMPABLE also suppresses a piped core pattern. */
static void no_core_dump(void) {
#ifdef __linux__
    struct rlimit rl = {0, 0};
    setrlimit(RLIMIT_CORE, &rl);
    prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
#endif
}

/* Run fn in a child; return 1 if it was killed by a signal (trapped). */
static int traps(void (*fn)(void)) {
    pid_t pid = fork();
    if (pid == 0) {
        no_core_dump();
        fn();
        _exit(0);                     /* only reached if it did not trap */
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFSIGNALED(st);
}

static void double_free(void) {
    void *p = asm_malloc(64);
    asm_free(p);
    asm_free(p);                      /* must trap */
}

int main(void) {
    printf("== asm alloc debug test ==\n");
    int fails = 0;

    /* normal usage still works */
    {
        unsigned char *a = asm_malloc(100);
        unsigned char *b = asm_calloc(10, 10);
        if (!a || !b || b[0] != 0 || b[99] != 0) {
            printf("FAIL: normal allocation\n");
            fails++;
        } else {
            memset(a, 0x33, 100);
            asm_free(a);
            asm_free(b);
        }
    }

    if (!traps(double_free)) {
        printf("FAIL: double free not detected\n");
        fails++;
    } else {
        printf("   double free -> trapped\n");
    }

    printf("== %d failures ==\n", fails);
    return fails != 0;
}
