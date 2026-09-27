/*==============================================================================
 * strcmp.S - high-performance AArch64 (AAPCS64 / Linux) string comparison
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Hand-written AArch64 port of src/strcmp.asm (x86-64 NASM). AAPCS64 calling
 * convention used throughout:
 *   - integer arguments arrive in x0..x7, the return value is in x0.
 *   - x0..x18 and x30 are caller-saved; x19..x29 are callee-saved.
 *   - the stack must remain 16-byte aligned at every call.
 *   - v0..v7 and v16..v31 are scratch; only the low 64 bits of v8..v15 are
 *     callee-saved, so this file stays within v0..v7 and v16..v31.
 *
 * Implements:
 *   int asm_strcmp    (const char *a, const char *b);
 *   int asm_strncmp   (const char *a, const char *b, size_t n);
 *   int asm_strcasecmp (const char *a, const char *b);
 *   int asm_strncasecmp(const char *a, const char *b, size_t n);
 *
 * The vector loops read 16 bytes from each string per step, but only when both
 * pointers sit at least 16 bytes below a 4096-byte page boundary, so a vector
 * load can never touch an unmapped page.  A NUL mask and an equality mask are
 * derived from the same block; the first difference or the earlier NUL decides
 * the result.  Case-insensitive compares fold ASCII 'A'..'Z' to lower case in
 * the vector with a branchless sequence before comparing.
 *============================================================================*/

#include "common_aarch64.inc"

    .text

/*==============================================================================
 * V_MASK - turn a 16-byte 0x00/0xFF NEON comparison result into a 16-bit mask
 *------------------------------------------------------------------------------
 * AArch64 has no pmovmskb, so the bit of each matching byte is gathered with
 * the classic "multiply by a magic constant" trick: masking the low bit of
 * every byte and multiplying by 0x0102040810204080 moves byte i's bit into bit
 * i of the top byte.  Both 64-bit halves are packed into one 16-bit value.
 *
 * Parameters:
 *   vq = source vector holding 0x00 or 0xFF per byte
 *   d0 = destination 64-bit register (receives the 16-bit mask in bits 0..15)
 *   d1 = scratch 64-bit register
 * Reads / clobbers: d0, d1 and the fixed constants in x9/x10.
 *============================================================================*/
.macro V_MASK vq, d0, d1
    umov    \d0, \vq\().d[0]            // low 64 bits of the comparison
    umov    \d1, \vq\().d[1]            // high 64 bits of the comparison
    and     \d0, \d0, x9                // keep bit 0 of every byte
    and     \d1, \d1, x9                // keep bit 0 of every byte
    mul     \d0, \d0, x10               // gather the low eight bits
    mul     \d1, \d1, x10               // gather the high eight bits
    lsr     \d0, \d0, #56               // move the gathered byte down
    lsr     \d1, \d1, #56               // move the gathered byte down
    orr     \d0, \d0, \d1, lsl #8       // bits 0..7 low, 8..15 high
.endm

/*==============================================================================
 * V_CTZ - count trailing zeroes of a non-zero 64-bit register
 *------------------------------------------------------------------------------
 * AArch64 lacks a CTZ instruction; reversing the bits and counting leading
 * zeroes on the result yields the index of the lowest set bit.
 *
 * Parameters:
 *   dst = destination 64-bit register
 *   src = source 64-bit register (must be non-zero)
 * Reads / clobbers: dst.
 *============================================================================*/
.macro V_CTZ dst, src
    rbit    \dst, \src                  // mirror so the low bit becomes high
    clz     \dst, \dst                  // count the leading zeroes
.endm

/*==============================================================================
 * V_GATHER_CONSTS - load the two constants used by V_MASK into x9 and x10
 *------------------------------------------------------------------------------
 * x9  = 0x0101010101010101 (keeps bit 0 of every byte)
 * x10 = 0x0102040810204080 (gathers the eight per-byte bits into one byte)
 *
 * Reads / clobbers: x9, x10.
 *============================================================================*/
.macro V_GATHER_CONSTS
    movz    x9, #0x0101                 // x9 = 0x0101010101010101
    movk    x9, #0x0101, lsl #16        // x9 |= 0x0101 << 16
    movk    x9, #0x0101, lsl #32        // x9 |= 0x0101 << 32
    movk    x9, #0x0101, lsl #48        // x9 |= 0x0101 << 48
    movz    x10, #0x4080                // x10 = 0x0102040810204080
    movk    x10, #0x1020, lsl #16       // x10 |= 0x1020 << 16
    movk    x10, #0x0408, lsl #32       // x10 |= 0x0408 << 32
    movk    x10, #0x0102, lsl #48       // x10 |= 0x0102 << 48
.endm

/*==============================================================================
 * int asm_strcmp(const char *a, const char *b)
 *------------------------------------------------------------------------------
 * Returns 0 if the strings are equal, otherwise the sign of the first
 * differing byte pair.  Bytes are compared 16 at a time in a page-safe window;
 * near a page end the routine falls back to a scalar byte loop.
 *
 * Parameters (AAPCS64):
 *   x0 = a (const char *) - first NUL-terminated string
 *   x1 = b (const char *) - second NUL-terminated string
 * Returns:
 *   w0 = (unsigned)a[i] - (unsigned)b[i] at the first differing byte, or 0
 * Uses / clobbers:
 *   Reads x0/x1; writes x0..x13, x9, x10 and v0..v4 (all caller-saved); leaf
 *   function, no calls, no callee-saved register touched.
 *============================================================================*/
    .globl asm_strcmp
    .type  asm_strcmp, %function
    .p2align 2
asm_strcmp:
    eor     v1.16b, v1.16b, v1.16b      // v1 = all zero (NUL detection)
    V_GATHER_CONSTS                     // x9/x10 = byte -> mask constants
    /* ---- page-safe vector window ---- */
.Lscmp_loop:
    and     x11, x0, #0xfff             // offset of a within its page
    movz    x12, #4096                  // x12 = page size
    sub     x11, x12, x11               // bytes from a to its page end
    and     x13, x1, #0xfff             // offset of b within its page
    sub     x13, x12, x13               // bytes from b to its page end
    cmp     x11, x13                    // compare the two windows
    csel    x11, x11, x13, lo           // x11 = min of the two windows
    cmp     x11, #16                    // at least one full vector safe?
    b.lo    .Lscmp_byte                 // no: finish with the scalar loop
    ldr     q0, [x0]                    // 16 bytes of a
    ldr     q2, [x1]                    // 16 bytes of b
    cmeq    v3.16b, v0.16b, v2.16b      // per-byte equality
    V_MASK  v3, x4, x5                  // x4 = 16-bit equality mask
    mvn     x5, x4                      // x5 = bits that differ
    uxth    w5, w5                      // keep only the 16 real lanes
    cbnz    x5, .Lscmp_diff             // some byte differs
    /* ---- all 16 bytes equal: did a string end inside the block? ---- */
    cmeq    v4.16b, v0.16b, v1.16b      // NUL bytes in a
    V_MASK  v4, x6, x7                  // x6 = 16-bit NUL mask
    cbnz    x6, .Lscmp_equal            // NUL reached in both strings
    add     x0, x0, #16                 // advance a
    add     x1, x1, #16                 // advance b
    b       .Lscmp_loop                 // compare the next window
.Lscmp_diff:
    V_CTZ   x4, x5                      // index of the first differing byte
    cmeq    v4.16b, v0.16b, v1.16b      // NUL bytes in a
    V_MASK  v4, x6, x7                  // x6 = 16-bit NUL mask
    cbz     x6, .Lscmp_emit             // no NUL before the difference
    V_CTZ   x6, x6                      // index of the first NUL
    cmp     x6, x4                      // did a string end before the difference?
    b.lo    .Lscmp_equal                // yes: the strings compare equal
.Lscmp_emit:
    ldrb    w5, [x0, x4]                // a's first differing byte
    ldrb    w6, [x1, x4]                // b's byte at the same position
    sub     w0, w5, w6                  // signed byte difference
    ret                                 // return the difference
.Lscmp_equal:
    mov     w0, #0                      // the strings compare equal
    ret                                 // return 0
    /* ---- scalar fallback near a page boundary ---- */
.Lscmp_byte:
    ldrb    w3, [x0], #1                // scalar byte of a
    ldrb    w4, [x1], #1                // scalar byte of b
    subs    w5, w3, w4                  // a - b
    b.ne    .Lscmp_emit_byte            // differ: return the difference
    cbnz    w3, .Lscmp_byte             // equal non-NUL: keep scanning
    mov     w0, #0                      // both NUL: equal
    ret                                 // return 0
.Lscmp_emit_byte:
    mov     w0, w5                      // return the byte difference
    ret                                 // return the difference
    .size asm_strcmp, .-asm_strcmp

/*==============================================================================
 * int asm_strncmp(const char *a, const char *b, size_t n)
 *------------------------------------------------------------------------------
 * Compares at most n bytes.  Returns 0 when the first n bytes are equal.
 * The vector loop also stops early when either string terminates first.
 *
 * Parameters (AAPCS64):
 *   x0 = a (const char *) - first string
 *   x1 = b (const char *) - second string
 *   x2 = n (size_t)       - maximum number of bytes to compare
 * Returns:
 *   w0 = (unsigned)a[i] - (unsigned)b[i] at the first differing byte within n
 *         bytes, or 0 when the prefixes are equal
 * Uses / clobbers:
 *   Reads x0/x1/x2; writes x0..x13, x9, x10 and v0..v4 (all caller-saved);
 *   leaf function, no calls, no callee-saved register touched.
 *============================================================================*/
    .globl asm_strncmp
    .type  asm_strncmp, %function
    .p2align 2
asm_strncmp:
    cbz     x2, .Lsncmp_equal           // n == 0: the prefixes are equal
    eor     v1.16b, v1.16b, v1.16b      // v1 = all zero (NUL detection)
    V_GATHER_CONSTS                     // x9/x10 = byte -> mask constants
    /* ---- page-safe vector window, bounded by the budget ---- */
.Lsncmp_loop:
    cmp     x2, #16                     // at least a full vector of budget?
    b.lo    .Lsncmp_byte                // no: finish with the scalar loop
    and     x11, x0, #0xfff             // offset of a within its page
    movz    x12, #4096                  // x12 = page size
    sub     x11, x12, x11               // bytes from a to its page end
    and     x13, x1, #0xfff             // offset of b within its page
    sub     x13, x12, x13               // bytes from b to its page end
    cmp     x11, x13                    // compare the two windows
    csel    x11, x11, x13, lo           // x11 = min of the two windows
    cmp     x11, #16                    // at least one full vector safe?
    b.lo    .Lsncmp_byte                // no: finish with the scalar loop
    ldr     q0, [x0]                    // 16 bytes of a
    ldr     q2, [x1]                    // 16 bytes of b
    cmeq    v3.16b, v0.16b, v2.16b      // per-byte equality
    V_MASK  v3, x4, x5                  // x4 = 16-bit equality mask
    mvn     x5, x4                      // x5 = bits that differ
    uxth    w5, w5                      // keep only the 16 real lanes
    cbnz    x5, .Lsncmp_diff            // some byte differs
    /* ---- all 16 bytes equal: did a string end inside the block? ---- */
    cmeq    v4.16b, v0.16b, v1.16b      // NUL bytes in a
    V_MASK  v4, x6, x7                  // x6 = 16-bit NUL mask
    cbnz    x6, .Lsncmp_equal           // NUL reached before the budget ended
    add     x0, x0, #16                 // advance a
    add     x1, x1, #16                 // advance b
    sub     x2, x2, #16                 // consume 16 bytes of budget
    b       .Lsncmp_loop                // compare the next window
.Lsncmp_diff:
    V_CTZ   x4, x5                      // index of the first differing byte
    cmeq    v4.16b, v0.16b, v1.16b      // NUL bytes in a
    V_MASK  v4, x6, x7                  // x6 = 16-bit NUL mask
    cbz     x6, .Lsncmp_emit            // no NUL before the difference
    V_CTZ   x6, x6                      // index of the first NUL
    cmp     x6, x4                      // did a string end before the difference?
    b.lo    .Lsncmp_equal               // yes: the prefixes are equal
.Lsncmp_emit:
    ldrb    w5, [x0, x4]                // a's first differing byte
    ldrb    w6, [x1, x4]                // b's byte at the same position
    sub     w0, w5, w6                  // signed byte difference
    ret                                 // return the difference
.Lsncmp_equal:
    mov     w0, #0                      // the prefixes compare equal
    ret                                 // return 0
    /* ---- scalar fallback: budget under 16 or a page edge ---- */
.Lsncmp_byte:
    cbz     x2, .Lsncmp_equal           // budget exhausted: equal
.Lsncmp_scan:
    ldrb    w3, [x0], #1                // scalar byte of a
    ldrb    w4, [x1], #1                // scalar byte of b
    subs    w5, w3, w4                  // a - b
    b.ne    .Lsncmp_emit_byte           // differ: return the difference
    cbz     w3, .Lsncmp_equal           // both NUL: equal
    subs    x2, x2, #1                  // consume one budget byte
    b.ne    .Lsncmp_scan                // more budget: keep scanning
    b       .Lsncmp_equal               // budget exhausted: equal
.Lsncmp_emit_byte:
    mov     w0, w5                      // return the byte difference
    ret                                 // return the difference
    .size asm_strncmp, .-asm_strncmp

/*==============================================================================
 * int asm_strcasecmp(const char *a, const char *b)
 *------------------------------------------------------------------------------
 * Case-insensitive (C/POSIX/ASCII locale) comparison of two NUL-terminated
 * strings.  ASCII 'A'..'Z' are folded to lower case in 16-byte NEON blocks
 * before comparing; the fallback byte loop folds each byte branchlessly.
 *
 * Parameters (AAPCS64):
 *   x0 = a (const char *) - first NUL-terminated string
 *   x1 = b (const char *) - second NUL-terminated string
 * Returns:
 *   w0 = signed difference of the first differing byte pair after folding, or 0
 * Uses / clobbers:
 *   Reads x0/x1; writes x0..x13, x9, x10 and v0..v4, v16..v18 (all
 *   caller-saved); leaf function, no calls, no callee-saved register touched.
 *============================================================================*/
    .globl asm_strcasecmp
    .type  asm_strcasecmp, %function
    .p2align 2
asm_strcasecmp:
    eor     v1.16b, v1.16b, v1.16b      // v1 = all zero (NUL detection)
    V_GATHER_CONSTS                     // x9/x10 = byte -> mask constants
    movi    v16.16b, #0x20              // v16 = lower-case bit (0x20)
    movi    v17.16b, #0x41              // v17 = 'A'
    movi    v18.16b, #25                // v18 = 'Z' - 'A'
    /* ---- page-safe vector window ---- */
.Lscc_loop:
    and     x11, x0, #0xfff             // offset of a within its page
    movz    x12, #4096                  // x12 = page size
    sub     x11, x12, x11               // bytes from a to its page end
    and     x13, x1, #0xfff             // offset of b within its page
    sub     x13, x12, x13               // bytes from b to its page end
    cmp     x11, x13                    // compare the two windows
    csel    x11, x11, x13, lo           // x11 = min of the two windows
    cmp     x11, #16                    // at least one full vector safe?
    b.lo    .Lscc_byte                  // no: finish with the scalar loop
    ldr     q0, [x0]                    // 16 bytes of a
    ldr     q2, [x1]                    // 16 bytes of b
    /* ---- fold a: c | 0x20 when 'A' <= c <= 'Z' ---- */
    sub     v3.16b, v0.16b, v17.16b     // t = c - 'A' (wraps below 'A')
    cmhs    v3.16b, v18.16b, v3.16b     // 0xFF where t <= 25 (upper case)
    and     v3.16b, v3.16b, v16.16b     // mask = 0x20 where upper case
    orr     v0.16b, v0.16b, v3.16b      // set the lower-case bit in a
    /* ---- fold b the same way ---- */
    sub     v4.16b, v2.16b, v17.16b     // t = c - 'A' (wraps below 'A')
    cmhs    v4.16b, v18.16b, v4.16b     // 0xFF where t <= 25 (upper case)
    and     v4.16b, v4.16b, v16.16b     // mask = 0x20 where upper case
    orr     v2.16b, v2.16b, v4.16b      // set the lower-case bit in b
    /* ---- compare the folded blocks ---- */
    cmeq    v3.16b, v0.16b, v2.16b      // per-byte equality of folded bytes
    V_MASK  v3, x4, x5                  // x4 = 16-bit equality mask
    mvn     x5, x4                      // x5 = bits that differ
    uxth    w5, w5                      // keep only the 16 real lanes
    cbnz    x5, .Lscc_diff              // some byte differs
    cmeq    v4.16b, v0.16b, v1.16b      // NUL bytes in folded a (NUL stays NUL)
    V_MASK  v4, x6, x7                  // x6 = 16-bit NUL mask
    cbnz    x6, .Lscc_equal             // NUL reached in both strings
    add     x0, x0, #16                 // advance a
    add     x1, x1, #16                 // advance b
    b       .Lscc_loop                  // compare the next window
.Lscc_diff:
    V_CTZ   x4, x5                      // index of the first differing byte
    cmeq    v4.16b, v0.16b, v1.16b      // NUL bytes in folded a
    V_MASK  v4, x6, x7                  // x6 = 16-bit NUL mask
    cbz     x6, .Lscc_emit              // no NUL before the difference
    V_CTZ   x6, x6                      // index of the first NUL
    cmp     x6, x4                      // did a string end before the difference?
    b.lo    .Lscc_equal                 // yes: the strings compare equal
.Lscc_emit:
    ldrb    w5, [x0, x4]                // a's first differing byte
    ldrb    w6, [x1, x4]                // b's byte at the same position
    sub     w7, w5, #0x41               // t = a - 'A'
    cmp     w7, #25                     // is a an upper-case letter?
    cset    w7, ls                      // w7 = 1 when 'A' <= a <= 'Z'
    lsl     w7, w7, #5                  // w7 = 0x20 when upper case
    orr     w5, w5, w7                  // fold a to lower case
    sub     w7, w6, #0x41               // t = b - 'A'
    cmp     w7, #25                     // is b an upper-case letter?
    cset    w7, ls                      // w7 = 1 when 'A' <= b <= 'Z'
    lsl     w7, w7, #5                  // w7 = 0x20 when upper case
    orr     w6, w6, w7                  // fold b to lower case
    sub     w0, w5, w6                  // signed folded byte difference
    ret                                 // return the difference
.Lscc_equal:
    mov     w0, #0                      // the strings compare equal
    ret                                 // return 0
    /* ---- scalar fallback near a page boundary ---- */
.Lscc_byte:
    ldrb    w3, [x0], #1                // scalar byte of a
    ldrb    w4, [x1], #1                // scalar byte of b
    sub     w5, w3, #0x41               // t = a - 'A'
    cmp     w5, #25                     // is a an upper-case letter?
    cset    w5, ls                      // w5 = 1 when 'A' <= a <= 'Z'
    lsl     w5, w5, #5                  // w5 = 0x20 when upper case
    orr     w3, w3, w5                  // fold a to lower case
    sub     w5, w4, #0x41               // t = b - 'A'
    cmp     w5, #25                     // is b an upper-case letter?
    cset    w5, ls                      // w5 = 1 when 'A' <= b <= 'Z'
    lsl     w5, w5, #5                  // w5 = 0x20 when upper case
    orr     w4, w4, w5                  // fold b to lower case
    subs    w5, w3, w4                  // folded a - folded b
    b.ne    .Lscc_emit_byte             // differ: return the difference
    cbz     w3, .Lscc_equal             // both folded to NUL: equal
    b       .Lscc_byte                  // keep scanning
.Lscc_emit_byte:
    mov     w0, w5                      // return the folded byte difference
    ret                                 // return the difference
    .size asm_strcasecmp, .-asm_strcasecmp

/*==============================================================================
 * int asm_strncasecmp(const char *a, const char *b, size_t n)
 *------------------------------------------------------------------------------
 * Case-insensitive comparison of at most n bytes, 16 bytes per vector step.
 * The vector loop stops on the budget, on an early NUL, or on a difference.
 *
 * Parameters (AAPCS64):
 *   x0 = a (const char *) - first string
 *   x1 = b (const char *) - second string
 *   x2 = n (size_t)       - maximum number of bytes to compare
 * Returns:
 *   w0 = signed difference of the first differing folded byte pair within n
 *         bytes, or 0 when the prefixes are equal
 * Uses / clobbers:
 *   Reads x0/x1/x2; writes x0..x13, x9, x10 and v0..v4, v16..v18 (all
 *   caller-saved); leaf function, no calls, no callee-saved register touched.
 *============================================================================*/
    .globl asm_strncasecmp
    .type  asm_strncasecmp, %function
    .p2align 2
asm_strncasecmp:
    cbz     x2, .Lsncc_equal            // n == 0: the prefixes are equal
    eor     v1.16b, v1.16b, v1.16b      // v1 = all zero (NUL detection)
    V_GATHER_CONSTS                     // x9/x10 = byte -> mask constants
    movi    v16.16b, #0x20              // v16 = lower-case bit (0x20)
    movi    v17.16b, #0x41              // v17 = 'A'
    movi    v18.16b, #25                // v18 = 'Z' - 'A'
    /* ---- page-safe vector window, bounded by the budget ---- */
.Lsncc_loop:
    cmp     x2, #16                     // at least a full vector of budget?
    b.lo    .Lsncc_byte                 // no: finish with the scalar loop
    and     x11, x0, #0xfff             // offset of a within its page
    movz    x12, #4096                  // x12 = page size
    sub     x11, x12, x11               // bytes from a to its page end
    and     x13, x1, #0xfff             // offset of b within its page
    sub     x13, x12, x13               // bytes from b to its page end
    cmp     x11, x13                    // compare the two windows
    csel    x11, x11, x13, lo           // x11 = min of the two windows
    cmp     x11, #16                    // at least one full vector safe?
    b.lo    .Lsncc_byte                 // no: finish with the scalar loop
    ldr     q0, [x0]                    // 16 bytes of a
    ldr     q2, [x1]                    // 16 bytes of b
    /* ---- fold a and b: c | 0x20 when 'A' <= c <= 'Z' ---- */
    sub     v3.16b, v0.16b, v17.16b     // t = c - 'A' (wraps below 'A')
    cmhs    v3.16b, v18.16b, v3.16b     // 0xFF where t <= 25 (upper case)
    and     v3.16b, v3.16b, v16.16b     // mask = 0x20 where upper case
    orr     v0.16b, v0.16b, v3.16b      // set the lower-case bit in a
    sub     v4.16b, v2.16b, v17.16b     // t = c - 'A' (wraps below 'A')
    cmhs    v4.16b, v18.16b, v4.16b     // 0xFF where t <= 25 (upper case)
    and     v4.16b, v4.16b, v16.16b     // mask = 0x20 where upper case
    orr     v2.16b, v2.16b, v4.16b      // set the lower-case bit in b
    /* ---- compare the folded blocks ---- */
    cmeq    v3.16b, v0.16b, v2.16b      // per-byte equality of folded bytes
    V_MASK  v3, x4, x5                  // x4 = 16-bit equality mask
    mvn     x5, x4                      // x5 = bits that differ
    uxth    w5, w5                      // keep only the 16 real lanes
    cbnz    x5, .Lsncc_diff             // some byte differs
    cmeq    v4.16b, v0.16b, v1.16b      // NUL bytes in folded a
    V_MASK  v4, x6, x7                  // x6 = 16-bit NUL mask
    cbnz    x6, .Lsncc_equal            // NUL reached before the budget ended
    add     x0, x0, #16                 // advance a
    add     x1, x1, #16                 // advance b
    sub     x2, x2, #16                 // consume 16 bytes of budget
    b       .Lsncc_loop                 // compare the next window
.Lsncc_diff:
    V_CTZ   x4, x5                      // index of the first differing byte
    cmeq    v4.16b, v0.16b, v1.16b      // NUL bytes in folded a
    V_MASK  v4, x6, x7                  // x6 = 16-bit NUL mask
    cbz     x6, .Lsncc_emit             // no NUL before the difference
    V_CTZ   x6, x6                      // index of the first NUL
    cmp     x6, x4                      // did a string end before the difference?
    b.lo    .Lsncc_equal                // yes: the prefixes are equal
.Lsncc_emit:
    ldrb    w5, [x0, x4]                // a's first differing byte
    ldrb    w6, [x1, x4]                // b's byte at the same position
    sub     w7, w5, #0x41               // t = a - 'A'
    cmp     w7, #25                     // is a an upper-case letter?
    cset    w7, ls                      // w7 = 1 when 'A' <= a <= 'Z'
    lsl     w7, w7, #5                  // w7 = 0x20 when upper case
    orr     w5, w5, w7                  // fold a to lower case
    sub     w7, w6, #0x41               // t = b - 'A'
    cmp     w7, #25                     // is b an upper-case letter?
    cset    w7, ls                      // w7 = 1 when 'A' <= b <= 'Z'
    lsl     w7, w7, #5                  // w7 = 0x20 when upper case
    orr     w6, w6, w7                  // fold b to lower case
    sub     w0, w5, w6                  // signed folded byte difference
    ret                                 // return the difference
.Lsncc_equal:
    mov     w0, #0                      // the prefixes compare equal
    ret                                 // return 0
    /* ---- scalar fallback: budget under 16 or a page edge ---- */
.Lsncc_byte:
    cbz     x2, .Lsncc_equal            // budget exhausted: equal
.Lsncc_scan:
    ldrb    w3, [x0], #1                // scalar byte of a
    ldrb    w4, [x1], #1                // scalar byte of b
    sub     w5, w3, #0x41               // t = a - 'A'
    cmp     w5, #25                     // is a an upper-case letter?
    cset    w5, ls                      // w5 = 1 when 'A' <= a <= 'Z'
    lsl     w5, w5, #5                  // w5 = 0x20 when upper case
    orr     w3, w3, w5                  // fold a to lower case
    sub     w5, w4, #0x41               // t = b - 'A'
    cmp     w5, #25                     // is b an upper-case letter?
    cset    w5, ls                      // w5 = 1 when 'A' <= b <= 'Z'
    lsl     w5, w5, #5                  // w5 = 0x20 when upper case
    orr     w4, w4, w5                  // fold b to lower case
    subs    w5, w3, w4                  // folded a - folded b
    b.ne    .Lsncc_emit_byte            // differ: return the difference
    cbz     w3, .Lsncc_equal            // both folded to NUL: equal
    subs    x2, x2, #1                  // consume one budget byte
    b.ne    .Lsncc_scan                 // more budget: keep scanning
    b       .Lsncc_equal                // budget exhausted: equal
.Lsncc_emit_byte:
    mov     w0, w5                      // return the folded byte difference
    ret                                 // return the difference
    .size asm_strncasecmp, .-asm_strncasecmp

GNU_STACK_NOTE                          // mark the stack non-executable
