/*==============================================================================
 * test_freestanding.c - link and run with -nostdlib, no OS, no libc
 *------------------------------------------------------------------------------
 * Uses only the freestanding surface: an arena over caller memory, the
 * string/memory/ctype routines, the freestanding math, the formatters/scanner
 * and the vector/matrix math. It defines its own _start and exits with a
 * syscall, so a successful run proves the subset needs no C runtime, no libc
 * and (after the arena change) no OS code. Covers x86-64 and AArch64 Linux.
 *============================================================================*/

#include "asmlib.h"
#include "asmlib_math.h"
#include "asmlib_matrix.h"

/* The compiler may lower a struct copy to memcpy/memset even with
 * -ffreestanding; give it the library's own freestanding versions. */
void *memcpy(void *d, const void *s, size_t n) { return asm_memcpy(d, s, n); }
void *memset(void *d, int c, size_t n) { return asm_memset(d, c, n); }
void *memmove(void *d, const void *s, size_t n) { return asm_memmove(d, s, n); }

static unsigned char pool[65536];

static void freestanding_exit(int code) {
#if defined(__x86_64__)
    __asm__ volatile("syscall" ::"a"(60), "D"((long)code) : "rcx", "r11", "memory");
#elif defined(__aarch64__)
    register long x8 __asm__("x8") = 93;      /* __NR_exit */
    register long x0 __asm__("x0") = code;
    __asm__ volatile("svc #0" ::"r"(x8), "r"(x0) : "memory");
#else
    (void)code;
#endif
    __builtin_unreachable();
}

/* The kernel enters _start with the stack 16-byte aligned, but a C function
 * expects rsp % 16 == 8 (a call pushed a return address). A tiny asm stub
 * aligns the stack and calls the real C body, which is not named _start. */
void asm_freestanding_main(void);

#if defined(__x86_64__)
__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "    xor %rbp, %rbp\n"
    "    and $-16, %rsp\n"
    "    call asm_freestanding_main\n"
    "    ud2\n");
#elif defined(__aarch64__)
__asm__(
    ".text\n"
    ".globl _start\n"
    "_start:\n"
    "    bl asm_freestanding_main\n");
#endif

void asm_freestanding_main(void) {
    int ok = 1;

    /* ---- arena over caller memory (no mmap) ---- */
    asm_arena a;
    if (asm_arena_init(&a, pool, sizeof pool) != 0) ok = 0;
    char *s = (char *)asm_arena_alloc(&a, 64);
    if (!s || asm_strlcpy(s, "hello world", 64) != 11) ok = 0;
    if (asm_strlen(s) != 11) ok = 0;
    if (asm_strcmp(s, "hello world") != 0) ok = 0;
    if (asm_isdigit('7') != 1 || asm_isalpha('7') != 0) ok = 0;

    /* ---- formatters / scanner ---- */
    char num[24];
    if (asm_u64toa(18446744073709551615ULL, num, sizeof num) != 20) ok = 0;
    if (asm_snprintf(num, sizeof num, "%05d", -7) != 5 || asm_strcmp(num, "-0007") != 0) ok = 0;
    { int v = 0; if (asm_sscanf("  42abc", "%d", &v) != 1 || v != 42) ok = 0; }

    /* ---- freestanding math ---- */
    double r = asm_sqrt(2.0);
    if (!(r > 1.4142 && r < 1.4143)) ok = 0;
    if (!(asm_sin(0.0) == 0.0)) ok = 0;

    /* ---- vector / matrix / quaternion ---- */
    asm_simd_vec3 x = asm_vec3_load((asm_vec3){1, 0, 0});
    asm_simd_vec3 y = asm_vec3_load((asm_vec3){0, 1, 0});
    asm_simd_vec3 z = asm_vec3_cross(x, y);
    if (!(z.x == 0.0f && z.y == 0.0f && z.z == 1.0f)) ok = 0;
    asm_quat q = asm_quat_from_axis_angle((asm_vec3){0, 0, 1}, 1.5707963f);
    asm_simd_vec3 rr = asm_quat_rotate_vec3(q, x);
    if (!(rr.x > -0.01f && rr.x < 0.01f && rr.y > 0.99f && rr.y < 1.01f)) ok = 0;

    freestanding_exit(ok ? 0 : 1);
}
