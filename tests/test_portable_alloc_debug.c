/*==============================================================================
 * test_portable_alloc_debug.c - debug-mode checks for the portable allocator
 *------------------------------------------------------------------------------
 * Compiled with -DASMLIB_ALLOC_DEBUG. Verifies the poison fill, the live
 * block/byte counters, and that a double free or a misaligned pointer traps
 * (checked in a forked child).
 *============================================================================*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <sys/resource.h>
#endif

#include "portable.h"

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

static int traps(void (*fn)(void)) {
    pid_t pid = fork();
    if (pid == 0) {
        no_core_dump();
        fn();
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFSIGNALED(st);
}

static void double_free(void) {
    void *p = asm_malloc(64);
    asm_free(p);
    asm_free(p);
}
static void misaligned_free(void) {
    unsigned char *p = (unsigned char *)asm_malloc(64);
    asm_free(p + 1);
}

int main(void) {
    printf("== portable allocator debug test ==\n");
    int fails = 0;

    size_t b0 = asm_alloc_debug_live_blocks();
    size_t y0 = asm_alloc_debug_live_bytes();

    unsigned char *p = (unsigned char *)asm_malloc(32);
    if (!p) { printf("FAIL: malloc\n"); return 1; }

    int poisoned = 1;
    for (int i = 0; i < 32; i++) if (p[i] != 0xCD) poisoned = 0;
    if (!poisoned) { printf("FAIL: fresh block not filled with 0xCD\n"); fails++; }

    if (asm_alloc_debug_live_blocks() != b0 + 1) { printf("FAIL: live block count\n"); fails++; }
    if (asm_alloc_debug_live_bytes() <= y0) { printf("FAIL: live byte count\n"); fails++; }

    asm_free(p);
    if (asm_alloc_debug_live_blocks() != b0) { printf("FAIL: live count after free\n"); fails++; }
    if (asm_alloc_debug_live_bytes() < y0) { printf("FAIL: live bytes underflow\n"); fails++; }

    if (!traps(double_free)) { printf("FAIL: double free not detected\n"); fails++; }
    else printf("   double free -> trapped\n");

    if (!traps(misaligned_free)) { printf("FAIL: misaligned free not detected\n"); fails++; }
    else printf("   misaligned free -> trapped\n");

    printf("== %d failures ==\n", fails);
    return fails != 0;
}
