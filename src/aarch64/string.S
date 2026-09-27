/*==============================================================================
 * string.S - high-performance AArch64 (AAPCS64 / Linux) C string routines
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Hand-written AArch64 port of src/string.asm (x86-64 NASM). AAPCS64 calling
 * convention used throughout:
 *   - integer arguments arrive in x0..x7, the return value is in x0.
 *   - x0..x18 and x30 are caller-saved; x19..x29 are callee-saved.
 *   - the stack must remain 16-byte aligned at every call.
 *   - v0..v7 and v16..v31 are scratch; only the low 64 bits of v8..v15 are
 *     callee-saved, so this file stays within v0..v7 and v16..v31.
 *
 * Public API (see include/asmlib.h):
 *   size_t asm_strlen (const char *s);
 *   size_t asm_strnlen(const char *s, size_t maxlen);
 *   char  *asm_strncpy(char *dst, const char *src, size_t n);
 *   char  *asm_stpncpy(char *dst, const char *src, size_t n);
 *   char  *asm_strncat(char *dst, const char *src, size_t n);
 *   size_t asm_strlcpy(char *dst, const char *src, size_t size);
 *   size_t asm_strlcat(char *dst, const char *src, size_t size);
 *
 * The NUL-scanning routines align the pointer down to a 16-byte boundary
 * first.  Because 4096 is a multiple of 16, that aligned block never leaves
 * the page that contains s, so a speculative vector read can never fault on an
 * unmapped page.  Every bounded writer only reads the caller's source window
 * and only writes inside the caller's destination window.
 *
 * This file is deliberately self-contained: the copy/fill helpers at the end
 * are local so the link step needs nothing else from the library.
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
 * size_t asm_strlen(const char *s)
 *------------------------------------------------------------------------------
 * Returns the number of bytes before the terminating NUL.  The first block is
 * aligned down to a 16-byte boundary (page safe) and the mask of NUL bytes is
 * shifted right so the bytes before s are ignored.
 *
 * Parameters (AAPCS64):
 *   x0 = s (const char *)  - NUL-terminated string to measure
 * Returns:
 *   x0 = number of bytes before the terminating NUL
 * Uses / clobbers:
 *   Reads x0; writes x0..x4, x9, x10 and v0/v1 (all caller-saved); leaf
 *   function, no calls, no callee-saved register touched.
 *============================================================================*/
    .globl asm_strlen
    .type  asm_strlen, %function
    .p2align 2
asm_strlen:
    /* ---- keep the original pointer and build a zero vector ---- */
    mov     x1, x0                      // x1 = s (the original pointer)
    eor     v1.16b, v1.16b, v1.16b      // v1 = all zero
    /* ---- constants for the byte -> bitmask gather ---- */
    movz    x9, #0x0101                 // x9 = 0x0101010101010101
    movk    x9, #0x0101, lsl #16        // x9 |= 0x0101 << 16
    movk    x9, #0x0101, lsl #32        // x9 |= 0x0101 << 32
    movk    x9, #0x0101, lsl #48        // x9 |= 0x0101 << 48
    movz    x10, #0x4080                // x10 = 0x0102040810204080
    movk    x10, #0x1020, lsl #16       // x10 |= 0x1020 << 16
    movk    x10, #0x0408, lsl #32       // x10 |= 0x0408 << 32
    movk    x10, #0x0102, lsl #48       // x10 |= 0x0102 << 48
    /* ---- aligned head block ---- */
    ubfx    x2, x0, #0, #4              // x2 = s & 15 (offset in the block)
    sub     x0, x0, x2                  // x0 = base = s & ~15 (page safe)
    ldr     q0, [x0]                    // load the aligned 16-byte block
    cmeq    v0.16b, v0.16b, v1.16b      // 0xFF in every NUL byte
    V_MASK  v0, x3, x4                  // x3 = 16-bit NUL mask for the block
    lsr     x3, x3, x2                  // drop bytes before s
    cbnz    x3, .Lsl_head               // NUL at/after s: length is known
    add     x0, x0, #16                 // advance past the head block
    /* ---- aligned main scan: 16-byte page-safe blocks ---- */
.Lsl_loop:
    ldr     q0, [x0]                    // load the next aligned block
    cmeq    v0.16b, v0.16b, v1.16b      // 0xFF in every NUL byte
    V_MASK  v0, x3, x4                  // x3 = 16-bit NUL mask
    cbnz    x3, .Lsl_found              // NUL in this block
    add     x0, x0, #16                 // advance one block
    b       .Lsl_loop                   // scan the next block
.Lsl_found:
    V_CTZ   x3, x3                      // index of the first NUL in the block
    add     x0, x0, x3                  // pointer to the terminating NUL
    sub     x0, x0, x1                  // length = NUL - s
    ret                                 // return the length
.Lsl_head:
    V_CTZ   x3, x3                      // index of the NUL relative to s
    mov     x0, x3                      // that index is the length
    ret                                 // return the length
    .size asm_strlen, .-asm_strlen

/*==============================================================================
 * size_t asm_strnlen(const char *s, size_t maxlen)
 *------------------------------------------------------------------------------
 * Returns min(strlen(s), maxlen) and never reads a byte at or beyond
 * s + maxlen.  A full aligned block is only read once it is known to fit
 * entirely inside [s, s + maxlen); the remainder is finished bytewise.
 *
 * Parameters (AAPCS64):
 *   x0 = s      (const char *) - string to measure
 *   x1 = maxlen (size_t)       - maximum number of bytes to examine
 * Returns:
 *   x0 = min(strlen(s), maxlen)
 * Uses / clobbers:
 *   Reads x0/x1; writes x0..x7, x9, x10 and v0/v1 (all caller-saved); leaf
 *   function, no calls, no callee-saved register touched.
 *============================================================================*/
    .globl asm_strnlen
    .type  asm_strnlen, %function
    .p2align 2
asm_strnlen:
    cbz     x1, .Lsnl_zero              // maxlen == 0: length is 0
    mov     x2, x0                      // x2 = s
    add     x3, x0, x1                  // x3 = end = s + maxlen
    cmp     x1, #16                     // fewer than a full vector available?
    b.lo    .Lsnl_scan                  // yes: pure scalar scan
    /* ---- build the zero vector and gather constants ---- */
    eor     v1.16b, v1.16b, v1.16b      // v1 = all zero
    movz    x9, #0x0101                 // x9 = 0x0101010101010101
    movk    x9, #0x0101, lsl #16        // x9 |= 0x0101 << 16
    movk    x9, #0x0101, lsl #32        // x9 |= 0x0101 << 32
    movk    x9, #0x0101, lsl #48        // x9 |= 0x0101 << 48
    movz    x10, #0x4080                // x10 = 0x0102040810204080
    movk    x10, #0x1020, lsl #16       // x10 |= 0x1020 << 16
    movk    x10, #0x0408, lsl #32       // x10 |= 0x0408 << 32
    movk    x10, #0x0102, lsl #48       // x10 |= 0x0102 << 48
    /* ---- head block: fits because maxlen >= 16 ---- */
    ubfx    x4, x0, #0, #4              // x4 = s & 15 (offset in the block)
    sub     x5, x0, x4                  // x5 = aligned base (page safe)
    ldr     q0, [x5]                    // load the aligned head block
    cmeq    v0.16b, v0.16b, v1.16b      // 0xFF in every NUL byte
    V_MASK  v0, x6, x7                  // x6 = 16-bit NUL mask
    lsr     x6, x6, x4                  // drop bytes before s
    cbnz    x6, .Lsnl_head              // NUL at/after s: length is known
    add     x5, x5, #16                 // advance past the head block
    /* ---- aligned loop: only blocks fully inside [s, end) ---- */
.Lsnl_loop:
    add     x6, x5, #16                 // x6 = end of this block
    cmp     x6, x3                      // whole block inside the bound?
    b.hi    .Lsnl_tail                  // no: finish bytewise
    ldr     q0, [x5]                    // load the aligned block
    cmeq    v0.16b, v0.16b, v1.16b      // 0xFF in every NUL byte
    V_MASK  v0, x6, x7                  // x6 = 16-bit NUL mask
    cbnz    x6, .Lsnl_found             // NUL in this block
    add     x5, x5, #16                 // advance one block
    b       .Lsnl_loop                  // scan the next block
.Lsnl_found:
    V_CTZ   x6, x6                      // index of the first NUL in the block
    add     x5, x5, x6                  // pointer to the NUL
    sub     x0, x5, x2                  // length = NUL - s
    ret                                 // return the length
.Lsnl_head:
    V_CTZ   x6, x6                      // index of the NUL relative to s
    mov     x0, x6                      // that index is the length
    ret                                 // return the length
.Lsnl_tail:
    mov     x0, x5                      // resume scanning from the block base
    /* ---- scalar tail, bounded by end ---- */
.Lsnl_scan:
    cmp     x0, x3                      // reached the bound?
    b.hs    .Lsnl_done                  // yes: capped at maxlen
    ldrb    w6, [x0]                    // next candidate byte
    cbz     w6, .Lsnl_done              // NUL: stop here
    add     x0, x0, #1                  // advance one byte
    b       .Lsnl_scan                  // keep scanning
.Lsnl_done:
    sub     x0, x0, x2                  // length = stop - s
    ret                                 // return the length
.Lsnl_zero:
    mov     x0, #0                      // maxlen == 0: length is 0
    ret                                 // return 0
    .size asm_strnlen, .-asm_strnlen

/*==============================================================================
 * char *asm_strncpy(char *dst, const char *src, size_t n)
 *------------------------------------------------------------------------------
 * Copies at most n bytes of src.  When src is shorter than n the rest of the
 * n-byte destination region is padded with NUL bytes.  Returns dst.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (char *)       - destination buffer
 *   x1 = src (const char *) - source string
 *   x2 = n   (size_t)       - maximum number of bytes to write
 * Returns:
 *   x0 = dst
 * Uses / clobbers:
 *   Preserves x19..x22 and x30; calls asm_strnlen and the local copy/fill
 *   helpers, inheriting their clobbers (x0..x7, x9, x10, v0/v1).
 *============================================================================*/
    .globl asm_strncpy
    .type  asm_strncpy, %function
    .p2align 2
asm_strncpy:
    /* ---- prologue: preserve callee-saved state across the calls ---- */
    stp     x19, x20, [sp, #-48]!       // save x19/x20, keep sp 16-byte aligned
    stp     x21, x22, [sp, #16]         // save x21/x22
    str     x30, [sp, #32]              // save the link register
    mov     x19, x0                     // x19 = dst
    mov     x20, x1                     // x20 = src
    mov     x21, x2                     // x21 = n
    /* ---- bounded source length, then the copy ---- */
    mov     x0, x20                     // arg0 = src
    mov     x1, x21                     // arg1 = n
    bl      asm_strnlen                 // x0 = min(strlen(src), n)
    mov     x22, x0                     // x22 = copied length
    mov     x0, x19                     // destination
    mov     x1, x20                     // source
    mov     x2, x22                     // count
    bl      .Lstr_copy                  // copy the string bytes
    /* ---- NUL-pad the tail when src was shorter than n ---- */
    cmp     x22, x21                    // copied everything requested?
    b.hs    .Lsnc_done                  // yes: no padding required
    add     x0, x19, x22                // start of the padding region
    mov     w1, #0                      // fill byte = NUL
    sub     x2, x21, x22                // remaining bytes to zero
    bl      .Lstr_fill                  // NUL-pad the remainder
.Lsnc_done:
    mov     x0, x19                     // return dst
    ldr     x30, [sp, #32]              // restore the link register
    ldp     x21, x22, [sp, #16]         // restore x21/x22
    ldp     x19, x20, [sp], #48         // restore x19/x20 and sp
    ret                                 // return dst
    .size asm_strncpy, .-asm_strncpy

/*==============================================================================
 * char *asm_stpncpy(char *dst, const char *src, size_t n)
 *------------------------------------------------------------------------------
 * POSIX stpncpy: like asm_strncpy, but returns a pointer to the NUL that
 * terminates dst when src fitted (strlen(src) < n), otherwise dst + n.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (char *)       - destination buffer
 *   x1 = src (const char *) - source string
 *   x2 = n   (size_t)       - size of the destination region
 * Returns:
 *   x0 = dst + strlen(src) when src fitted (the written NUL), else dst + n
 * Uses / clobbers:
 *   Preserves x19..x22 and x30; calls asm_strnlen and the local copy/fill
 *   helpers, inheriting their clobbers (x0..x7, x9, x10, v0/v1).
 *============================================================================*/
    .globl asm_stpncpy
    .type  asm_stpncpy, %function
    .p2align 2
asm_stpncpy:
    /* ---- prologue: preserve callee-saved state across the calls ---- */
    stp     x19, x20, [sp, #-48]!       // save x19/x20, keep sp 16-byte aligned
    stp     x21, x22, [sp, #16]         // save x21/x22
    str     x30, [sp, #32]              // save the link register
    mov     x19, x0                     // x19 = dst
    mov     x20, x1                     // x20 = src
    mov     x21, x2                     // x21 = n
    /* ---- bounded source length, then the copy ---- */
    mov     x0, x20                     // arg0 = src
    mov     x1, x21                     // arg1 = n
    bl      asm_strnlen                 // x0 = min(strlen(src), n)
    mov     x22, x0                     // x22 = copied length
    mov     x0, x19                     // destination
    mov     x1, x20                     // source
    mov     x2, x22                     // count
    bl      .Lstr_copy                  // copy the string bytes
    /* ---- src shorter than n: pad, and return the written NUL ---- */
    cmp     x22, x21                    // did src fill the whole region?
    b.hs    .Lstp_full                  // yes: no terminating NUL was written
    add     x0, x19, x22                // start of the padding region
    mov     w1, #0                      // fill byte = NUL
    sub     x2, x21, x22                // remaining bytes to zero
    bl      .Lstr_fill                  // NUL-pad the remainder
    add     x0, x19, x22                // return the terminating NUL
    b       .Lstp_done                  // common epilogue
.Lstp_full:
    add     x0, x19, x21                // return dst + n
.Lstp_done:
    ldr     x30, [sp, #32]              // restore the link register
    ldp     x21, x22, [sp, #16]         // restore x21/x22
    ldp     x19, x20, [sp], #48         // restore x19/x20 and sp
    ret                                 // return the result pointer
    .size asm_stpncpy, .-asm_stpncpy

/*==============================================================================
 * char *asm_strncat(char *dst, const char *src, size_t n)
 *------------------------------------------------------------------------------
 * Appends at most n bytes of src to dst and always NUL-terminates.  Returns
 * dst.  dst must already be NUL-terminated.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (char *)       - NUL-terminated destination string
 *   x1 = src (const char *) - string to append
 *   x2 = n   (size_t)       - maximum number of bytes to append
 * Returns:
 *   x0 = dst
 * Uses / clobbers:
 *   Preserves x19..x23 and x30; calls asm_strlen, asm_strnlen and the local
 *   copy helper, inheriting their clobbers (x0..x7, x9, x10, v0/v1).
 *============================================================================*/
    .globl asm_strncat
    .type  asm_strncat, %function
    .p2align 2
asm_strncat:
    /* ---- prologue: preserve callee-saved state across the calls ---- */
    stp     x19, x20, [sp, #-64]!       // save x19/x20, keep sp 16-byte aligned
    stp     x21, x22, [sp, #16]         // save x21/x22
    stp     x23, x30, [sp, #32]         // save x23 and the link register
    mov     x19, x0                     // x19 = dst
    mov     x20, x1                     // x20 = src
    mov     x21, x2                     // x21 = n
    /* ---- destination length, then the bounded source length ---- */
    mov     x0, x19                     // arg0 = dst
    bl      asm_strlen                  // x0 = strlen(dst)
    mov     x22, x0                     // x22 = append position offset
    mov     x0, x20                     // arg0 = src
    mov     x1, x21                     // arg1 = n
    bl      asm_strnlen                 // x0 = min(strlen(src), n)
    mov     x23, x0                     // x23 = number of bytes to append
    /* ---- append the bytes and terminate ---- */
    add     x0, x19, x22                // destination = dst + strlen(dst)
    mov     x1, x20                     // source
    mov     x2, x23                     // bytes to append
    bl      .Lstr_copy                  // append the bytes
    add     x3, x19, x22                // x3 = dst + strlen(dst)
    add     x3, x3, x23                 // x3 = dst + strlen(dst) + appended
    strb    wzr, [x3]                   // NUL-terminate the result
    mov     x0, x19                     // return dst
    ldp     x23, x30, [sp, #32]         // restore x23 and the link register
    ldp     x21, x22, [sp, #16]         // restore x21/x22
    ldp     x19, x20, [sp], #64         // restore x19/x20 and sp
    ret                                 // return dst
    .size asm_strncat, .-asm_strncat

/*==============================================================================
 * size_t asm_strlcpy(char *dst, const char *src, size_t size)
 *------------------------------------------------------------------------------
 * BSD strlcpy: copies at most size-1 bytes of src, always NUL-terminates when
 * size > 0, and returns strlen(src).  Never reads or writes past dst[size-1].
 *
 * Parameters (AAPCS64):
 *   x0 = dst  (char *)       - destination buffer
 *   x1 = src  (const char *) - source string
 *   x2 = size (size_t)       - total size of the destination buffer
 * Returns:
 *   x0 = strlen(src)
 * Uses / clobbers:
 *   Preserves x19..x23 and x30; calls asm_strlen and the local copy helper,
 *   inheriting their clobbers (x0..x7, x9, x10, v0/v1).
 *============================================================================*/
    .globl asm_strlcpy
    .type  asm_strlcpy, %function
    .p2align 2
asm_strlcpy:
    /* ---- prologue: preserve callee-saved state across the calls ---- */
    stp     x19, x20, [sp, #-64]!       // save x19/x20, keep sp 16-byte aligned
    stp     x21, x22, [sp, #16]         // save x21/x22
    stp     x23, x30, [sp, #32]         // save x23 and the link register
    mov     x19, x0                     // x19 = dst
    mov     x20, x1                     // x20 = src
    mov     x21, x2                     // x21 = size
    /* ---- measure src; it is also the return value ---- */
    mov     x0, x20                     // arg0 = src
    bl      asm_strlen                  // x0 = strlen(src)
    mov     x22, x0                     // x22 = strlen(src)
    cbz     x21, .Lslc_ret              // size == 0: write nothing
    /* ---- choose min(strlen(src), size-1) bytes to copy ---- */
    sub     x23, x21, #1                // x23 = size - 1 (maximum copy)
    cmp     x22, x23                    // strlen(src) < size - 1?
    b.lo    .Lslc_use_len               // yes: copy the whole string
    b       .Lslc_copy                  // no: copy size-1 bytes (x23)
.Lslc_use_len:
    mov     x23, x22                    // copy strlen(src) bytes
.Lslc_copy:
    mov     x0, x19                     // destination
    mov     x1, x20                     // source
    mov     x2, x23                     // count
    bl      .Lstr_copy                  // copy the bytes
    strb    wzr, [x19, x23]             // NUL-terminate at dst[copy]
.Lslc_ret:
    mov     x0, x22                     // return strlen(src)
    ldp     x23, x30, [sp, #32]         // restore x23 and the link register
    ldp     x21, x22, [sp, #16]         // restore x21/x22
    ldp     x19, x20, [sp], #64         // restore x19/x20 and sp
    ret                                 // return strlen(src)
    .size asm_strlcpy, .-asm_strlcpy

/*==============================================================================
 * size_t asm_strlcat(char *dst, const char *src, size_t size)
 *------------------------------------------------------------------------------
 * BSD strlcat: appends at most size - strlen(dst) - 1 bytes of src, always
 * NUL-terminates, and returns min(size, strlen(dst)) + strlen(src).  When no
 * NUL exists within the first size bytes of dst it writes nothing and returns
 * size + strlen(src).  Never writes past dst[size-1].
 *
 * Parameters (AAPCS64):
 *   x0 = dst  (char *)       - NUL-terminated destination string
 *   x1 = src  (const char *) - string to append
 *   x2 = size (size_t)       - total size of the destination buffer
 * Returns:
 *   x0 = min(size, strlen(dst)) + strlen(src)
 * Uses / clobbers:
 *   Preserves x19..x24 and x30; calls asm_strnlen, asm_strlen and the local
 *   copy helper, inheriting their clobbers (x0..x7, x9, x10, v0/v1).
 *============================================================================*/
    .globl asm_strlcat
    .type  asm_strlcat, %function
    .p2align 2
asm_strlcat:
    /* ---- prologue: preserve callee-saved state across the calls ---- */
    stp     x19, x20, [sp, #-64]!       // save x19/x20, keep sp 16-byte aligned
    stp     x21, x22, [sp, #16]         // save x21/x22
    stp     x23, x24, [sp, #32]         // save x23/x24
    str     x30, [sp, #48]              // save the link register
    mov     x19, x0                     // x19 = dst
    mov     x20, x1                     // x20 = src
    mov     x21, x2                     // x21 = size
    /* ---- bounded dst length and full src length ---- */
    mov     x0, x19                     // arg0 = dst
    mov     x1, x21                     // arg1 = size
    bl      asm_strnlen                 // x0 = min(strlen(dst), size)
    mov     x22, x0                     // x22 = bounded dst length
    mov     x0, x20                     // arg0 = src
    bl      asm_strlen                  // x0 = strlen(src)
    mov     x23, x0                     // x23 = strlen(src)
    /* ---- no NUL within size: write nothing ---- */
    cmp     x22, x21                    // bounded length reached size?
    b.eq    .Lslcat_nul                 // yes: no terminating NUL, no write
    /* ---- room = size - dlen - 1, append min(strlen(src), room) ---- */
    sub     x24, x21, x22               // x24 = size - dlen
    sub     x24, x24, #1                // x24 = room
    cmp     x23, x24                    // strlen(src) < room?
    b.lo    .Lslcat_use_len             // yes: append the whole string
    b       .Lslcat_copy                // no: append only the room bytes
.Lslcat_use_len:
    mov     x24, x23                    // append strlen(src) bytes
.Lslcat_copy:
    add     x0, x19, x22                // destination = dst + dlen
    mov     x1, x20                     // source
    mov     x2, x24                     // bytes to append
    bl      .Lstr_copy                  // append the bytes
    add     x3, x19, x22                // x3 = dst + dlen
    add     x3, x3, x24                 // x3 = dst + dlen + appended
    strb    wzr, [x3]                   // NUL-terminate the result
    add     x0, x22, x23                // return dlen + strlen(src)
    b       .Lslcat_done                // common epilogue
.Lslcat_nul:
    add     x0, x21, x23                // return size + strlen(src)
.Lslcat_done:
    ldr     x30, [sp, #48]              // restore the link register
    ldp     x23, x24, [sp, #32]         // restore x23/x24
    ldp     x21, x22, [sp, #16]         // restore x21/x22
    ldp     x19, x20, [sp], #64         // restore x19/x20 and sp
    ret                                 // return the computed length
    .size asm_strlcat, .-asm_strlcat

/*==============================================================================
 * .Lstr_copy - copy exactly x2 bytes from x1 to x0
 *------------------------------------------------------------------------------
 * Local helper for the bounded string writers.  Copies 16 bytes per iteration
 * with NEON while a full vector remains, then finishes bytewise.  The source
 * and destination windows are honoured exactly: nothing outside
 * [src, src+n) is read and nothing outside [dst, dst+n) is written.
 *
 * Parameters:
 *   x0 = dst, x1 = src, x2 = n
 * Reads / clobbers:
 *   x0, x1, x2, x3, q0 and x30 (a call is made to reach it).
 *============================================================================*/
.Lstr_copy:
    cbz     x2, .Lstr_copy_done         // n == 0: nothing to copy
.Lstr_copy_loop:
    cmp     x2, #16                     // a full vector left?
    b.lo    .Lstr_copy_tail             // no: finish bytewise
    ldr     q0, [x1]                    // load 16 source bytes
    str     q0, [x0]                    // store 16 destination bytes
    add     x1, x1, #16                 // advance the source cursor
    add     x0, x0, #16                 // advance the destination cursor
    sub     x2, x2, #16                 // consume 16 bytes
    b       .Lstr_copy_loop             // next block
.Lstr_copy_tail:
    cbz     x2, .Lstr_copy_done         // nothing left
.Lstr_copy_byte:
    ldrb    w3, [x1], #1                // load one source byte, advance
    strb    w3, [x0], #1                // store one destination byte
    subs    x2, x2, #1                  // one fewer byte
    b.ne    .Lstr_copy_byte             // continue
.Lstr_copy_done:
    ret                                 // return to the caller

/*==============================================================================
 * .Lstr_fill - fill exactly x2 bytes at x0 with the low byte of w1
 *------------------------------------------------------------------------------
 * Local helper for the NUL-padding in the bounded string writers.  Stores 16
 * bytes per iteration while a full vector remains, then finishes bytewise.
 * Nothing outside [dst, dst+n) is written.
 *
 * Parameters:
 *   x0 = dst, w1 = fill byte (low 8 bits used), x2 = n
 * Reads / clobbers:
 *   x0, x1, x2, q0 and x30 (a call is made to reach it).
 *============================================================================*/
.Lstr_fill:
    dup     v0.16b, w1                  // broadcast the fill byte to all lanes
    cbz     x2, .Lstr_fill_done         // n == 0: nothing to fill
.Lstr_fill_loop:
    cmp     x2, #16                     // a full vector left?
    b.lo    .Lstr_fill_tail             // no: finish bytewise
    str     q0, [x0]                    // store 16 bytes
    add     x0, x0, #16                 // advance the destination cursor
    sub     x2, x2, #16                 // consume 16 bytes
    b       .Lstr_fill_loop             // next block
.Lstr_fill_tail:
    cbz     x2, .Lstr_fill_done         // nothing left
.Lstr_fill_byte:
    strb    w1, [x0], #1                // store one byte, advance
    subs    x2, x2, #1                  // one fewer byte
    b.ne    .Lstr_fill_byte             // continue
.Lstr_fill_done:
    ret                                 // return to the caller

GNU_STACK_NOTE                          // mark the stack non-executable
