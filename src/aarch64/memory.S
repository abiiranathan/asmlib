/*==============================================================================
 * memory.S - AArch64 (AAPCS64 / Linux) memory primitives
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * Hand-written AArch64 port of src/memory.asm (x86-64 NASM). AAPCS64 calling
 * convention used throughout:
 *   - integer arguments arrive in x0..x7, the return value is in x0.
 *   - x0..x18 and x30 are caller-saved; x19..x29 are callee-saved.
 *   - the stack must remain 16-byte aligned at every call.
 *   - q0..q7 are scratch; the low 64 bits of v8..v15 are callee-saved, so this
 *     file stays within q0..q7 and never clobbers v8..v15.
 *
 * Public API (see include/asmlib.h):
 *   void *asm_memcpy (void *dst, const void *src, size_t n);        return dst
 *   void *asm_mempcpy(void *dst, const void *src, size_t n);        return dst+n
 *   void *asm_memccpy(void *dst, const void *src, int c, size_t n); stop at c
 *   void *asm_memmove(void *dst, const void *src, size_t n);        return dst
 *   void *asm_memset (void *dst, int c, size_t n);                  return dst
 *   void *asm_bzero  (void *dst, size_t n);                         return dst
 *   void  asm_explicit_bzero(void *dst, size_t n);
 *   int   asm_memcmp (const void *a, const void *b, size_t n);      <0 / 0 / >0
 *   void *asm_memchr (const void *s, int c, size_t n);              first c / NULL
 *   void *asm_memrchr(const void *s, int c, size_t n);              last  c / NULL
 *
 * Page safety: unlike the x86 version, which aligns buffers down to a page for
 * its scans, every load and store here is kept strictly inside the caller's
 * [base, base+n) window.  A buffer whose last byte abuts a PROT_NONE guard
 * page is therefore never touched out of bounds, and a speculative vector load
 * can never straddle into an unmapped page.
 *============================================================================*/

#include "common_aarch64.inc"

    .text

/*==============================================================================
 * void *asm_memcpy(void *dst, const void *src, size_t n)
 *------------------------------------------------------------------------------
 * Copies exactly n bytes from src to dst. src and dst must not overlap.
 * Returns dst. Small sizes use overlapping scalar/vector moves; large sizes use
 * an unrolled 64-byte NEON loop with an overlapping 64-byte tail.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (void *)        - destination buffer start
 *   x1 = src (const void *)  - source buffer start
 *   x2 = n   (size_t)        - number of bytes to copy
 * Returns:
 *   x0 = dst (the original destination pointer)
 * Uses / clobbers:
 *   Writes x3..x7 and q0..q7 (all caller-saved); x0 is returned unchanged.
 *============================================================================*/
    .globl asm_memcpy
    .type  asm_memcpy, %function
    .p2align 2
asm_memcpy:
    /* ---- size dispatch: pick the smallest page-safe copy shape ---------- */
    cmp     x2, #32                     // n >= 32 bytes?
    b.hs    .Lcpy_ge32                  // yes: enter the vector shapes
    cmp     x2, #16                     // 16 <= n < 32?
    b.hs    .Lcpy_16_31                 // yes: two overlapping 16-byte vectors
    cmp     x2, #8                      // 8 <= n < 16?
    b.hs    .Lcpy_8_15                  // yes: two overlapping 8-byte words
    cmp     x2, #4                      // 4 <= n < 8?
    b.hs    .Lcpy_4_7                   // yes: two overlapping 4-byte words
    cbz     x2, .Lcpy_done              // n == 0: nothing to do
    /* ---- 1..3 bytes: first and last, plus the middle when n == 3 -------- */
    ldrb    w3, [x1]                    // load source byte 0
    sub     x4, x2, #1                  // x4 = n-1
    ldrb    w5, [x1, x4]                // load source byte n-1
    strb    w3, [x0]                    // store destination byte 0
    strb    w5, [x0, x4]                // store destination byte n-1
    cmp     x2, #3                      // exactly three bytes?
    b.ne    .Lcpy_done                  // no: 1 or 2 are already covered
    ldrb    w3, [x1, #1]                // load the middle source byte
    strb    w3, [x0, #1]                // store the middle destination byte
.Lcpy_done:
    ret                                 // return dst (x0)
    /* ---- 4 <= n < 8: two overlapping 4-byte moves ----------------------- */
.Lcpy_4_7:
    sub     x4, x2, #4                  // x4 = n-4
    ldr     w3, [x1]                    // load the first 4 source bytes
    add     x5, x1, x4                  // x5 = &src[n-4]
    ldr     w6, [x5]                    // load the last 4 source bytes
    str     w3, [x0]                    // store the first 4 destination bytes
    add     x5, x0, x4                  // x5 = &dst[n-4]
    str     w6, [x5]                    // store the last 4 destination bytes
    ret                                 // return dst (x0)
    /* ---- 8 <= n < 16: two overlapping 8-byte moves ---------------------- */
.Lcpy_8_15:
    sub     x4, x2, #8                  // x4 = n-8
    ldr     x3, [x1]                    // load the first 8 source bytes
    add     x5, x1, x4                  // x5 = &src[n-8]
    ldr     x6, [x5]                    // load the last 8 source bytes
    str     x3, [x0]                    // store the first 8 destination bytes
    add     x5, x0, x4                  // x5 = &dst[n-8]
    str     x6, [x5]                    // store the last 8 destination bytes
    ret                                 // return dst (x0)
    /* ---- 16 <= n < 32: two overlapping 16-byte vector moves ------------- */
.Lcpy_16_31:
    sub     x4, x2, #16                 // x4 = n-16
    ldr     q0, [x1]                    // load the first 16 source bytes
    add     x5, x1, x4                  // x5 = &src[n-16]
    ldr     q1, [x5]                    // load the last 16 source bytes
    str     q0, [x0]                    // store the first 16 destination bytes
    add     x5, x0, x4                  // x5 = &dst[n-16]
    str     q1, [x5]                    // store the last 16 destination bytes
    ret                                 // return dst (x0)
    /* ---- n >= 32: vectorised shapes start here ------------------------- */
.Lcpy_ge32:
    cmp     x2, #64                     // n >= 64?
    b.hs    .Lcpy_ge64                  // yes: 64-byte shapes
    /* ---- 32 <= n < 64: first 32 and last 32 overlap --------------------- */
    ldp     q0, q1, [x1]                // load source bytes +0  .. +31
    add     x3, x1, x2                  // x3 = src + n
    sub     x3, x3, #32                 // x3 = src + n - 32
    ldp     q2, q3, [x3]                // load source bytes n-32 .. n-1
    stp     q0, q1, [x0]                // store dest bytes +0  .. +31
    add     x4, x0, x2                  // x4 = dst + n
    sub     x4, x4, #32                 // x4 = dst + n - 32
    stp     q2, q3, [x4]                // store dest bytes n-32 .. n-1
    ret                                 // return dst (x0)
    /* ---- n >= 64: 64-byte shapes --------------------------------------- */
.Lcpy_ge64:
    cmp     x2, #128                    // n >= 128?
    b.hs    .Lcpy_ge128                 // yes: run the 64-byte loop
    /* ---- 64 <= n < 128: first 64 and last 64 overlap -------------------- */
    ldp     q0, q1, [x1]                // load source bytes +0  .. +31
    ldp     q2, q3, [x1, #32]           // load source bytes +32 .. +63
    add     x3, x1, x2                  // x3 = src + n
    sub     x3, x3, #64                 // x3 = src + n - 64
    ldp     q4, q5, [x3]                // load source bytes n-64 .. n-33
    ldp     q6, q7, [x3, #32]           // load source bytes n-32 .. n-1
    stp     q0, q1, [x0]                // store dest bytes +0  .. +31
    stp     q2, q3, [x0, #32]           // store dest bytes +32 .. +63
    add     x4, x0, x2                  // x4 = dst + n
    sub     x4, x4, #64                 // x4 = dst + n - 64
    stp     q4, q5, [x4]                // store dest bytes n-64 .. n-33
    stp     q6, q7, [x4, #32]           // store dest bytes n-32 .. n-1
    ret                                 // return dst (x0)
    /* ---- n >= 128: 64 bytes per iteration, overlapping 64-byte tail ----- */
.Lcpy_ge128:
    mov     x5, x1                      // x5 = source cursor, starts at src
    mov     x6, x0                      // x6 = dest cursor, starts at dst
    add     x7, x1, x2                  // x7 = src + n (source end)
    and     x3, x2, #-64                // x3 = n rounded down to a multiple of 64
    add     x3, x1, x3                  // x3 = end of the full-block region
.Lcpy_loop64:
    ldp     q0, q1, [x5]                // load source bytes +0  .. +31
    ldp     q2, q3, [x5, #32]           // load source bytes +32 .. +63
    stp     q0, q1, [x6]                // store dest bytes +0  .. +31
    stp     q2, q3, [x6, #32]           // store dest bytes +32 .. +63
    add     x5, x5, #64                 // advance the source cursor
    add     x6, x6, #64                 // advance the dest cursor
    cmp     x5, x3                      // copied every full 64-byte block?
    b.lo    .Lcpy_loop64                // no: keep going
    /* ---- overlapping final 64 bytes cover the tail exactly -------------- */
    sub     x5, x7, #64                 // x5 = src + n - 64
    add     x6, x0, x2                  // x6 = dst + n
    sub     x6, x6, #64                 // x6 = dst + n - 64
    ldp     q0, q1, [x5]                // load source bytes n-64 .. n-33
    ldp     q2, q3, [x5, #32]           // load source bytes n-32 .. n-1
    stp     q0, q1, [x6]                // store dest bytes n-64 .. n-33
    stp     q2, q3, [x6, #32]           // store dest bytes n-32 .. n-1
    ret                                 // return dst (x0)
    .size asm_memcpy, .-asm_memcpy

/*==============================================================================
 * void *asm_mempcpy(void *dst, const void *src, size_t n)
 *------------------------------------------------------------------------------
 * Copies exactly n non-overlapping bytes like asm_memcpy and returns dst + n.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (void *)        - destination buffer start
 *   x1 = src (const void *)  - source buffer start
 *   x2 = n   (size_t)        - number of bytes to copy
 * Returns:
 *   x0 = dst + n (a pointer just past the copied region)
 * Uses / clobbers:
 *   Saves/restores callee-saved x19 and the link register x30; forwards its
 *   arguments to asm_memcpy and therefore inherits that routine's clobbers.
 *============================================================================*/
    .globl asm_mempcpy
    .type  asm_mempcpy, %function
    .p2align 2
asm_mempcpy:
    stp     x19, x30, [sp, #-16]!       // preserve x19 and lr (16-byte aligned)
    add     x19, x0, x2                 // x19 = dst + n (the return value)
    bl      asm_memcpy                  // x0 already dst, x1 src, x2 n
    mov     x0, x19                     // return dst + n
    ldp     x19, x30, [sp], #16         // restore x19 and lr
    ret                                 // return dst + n in x0
    .size asm_mempcpy, .-asm_mempcpy

/*==============================================================================
 * void *asm_memccpy(void *dst, const void *src, int c, size_t n)
 *------------------------------------------------------------------------------
 * Copies bytes from src to dst, stopping after the first byte equal to
 * (unsigned char)c. Returns a pointer just past that byte in dst, or NULL if
 * none of the first n bytes equals c (in which case all n bytes are copied).
 * Never reads or writes outside the n-byte windows. Built on asm_memchr and
 * asm_memcpy.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (void *)        - destination buffer start
 *   x1 = src (const void *)  - source buffer start
 *   w2 = c   (int)           - stop byte; only the low 8 bits are used
 *   x3 = n   (size_t)        - maximum number of bytes to copy
 * Returns:
 *   x0 = pointer just past the copy of the first c in dst, or NULL
 * Uses / clobbers:
 *   Saves/restores callee-saved x19/x20/x21 and the link register x30; calls
 *   asm_memchr and asm_memcpy and inherits their clobbers.
 *============================================================================*/
    .globl asm_memccpy
    .type  asm_memccpy, %function
    .p2align 2
asm_memccpy:
    stp     x19, x20, [sp, #-32]!       // preserve x19/x20, keep sp aligned
    stp     x21, x30, [sp, #16]         // preserve x21 and lr
    mov     x19, x0                     // x19 = dst
    mov     x20, x1                     // x20 = src
    mov     x21, x3                     // x21 = n
    /* ---- locate the first c within the first n source bytes ------------ */
    mov     x0, x1                      // arg0 = src
    mov     w1, w2                      // arg1 = c
    mov     x2, x3                      // arg2 = n
    bl      asm_memchr                  // x0 = first match, or NULL
    cbz     x0, .Lcc_not_found          // c absent: copy all n, return NULL
    /* ---- copy through the matching byte -------------------------------- */
    sub     x21, x0, x20                // x21 = index of the first c
    add     x21, x21, #1                // x21 = bytes to copy (index + 1)
    mov     x0, x19                     // destination
    mov     x1, x20                     // source
    mov     x2, x21                     // count = index + 1
    bl      asm_memcpy                  // copy src[0 .. index]
    add     x0, x19, x21                // return dst + bytes copied
    b       .Lcc_done                   // common epilogue
    /* ---- c absent: copy the whole window and report no match ----------- */
.Lcc_not_found:
    mov     x0, x19                     // destination
    mov     x1, x20                     // source
    mov     x2, x21                     // count = n
    bl      asm_memcpy                  // copy all n bytes
    mov     x0, #0                      // return NULL
.Lcc_done:
    ldp     x21, x30, [sp, #16]         // restore x21 and lr
    ldp     x19, x20, [sp], #32         // restore x19/x20 and sp
    ret                                 // return x0
    .size asm_memccpy, .-asm_memccpy

/*==============================================================================
 * void *asm_memmove(void *dst, const void *src, size_t n)
 *------------------------------------------------------------------------------
 * Like memcpy but the buffers may overlap. Chooses the copy direction so a
 * byte is always read before it can be overwritten. Returns dst.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (void *)        - destination buffer start
 *   x1 = src (const void *)  - source buffer start
 *   x2 = n   (size_t)        - number of bytes to move
 * Returns:
 *   x0 = dst (the original destination pointer)
 * Uses / clobbers:
 *   Writes x3..x7 and q0..q3; may tail-call asm_memcpy (which also clobbers
 *   q4..q7).  x0 is preserved as the return value.
 *============================================================================*/
    .globl asm_memmove
    .type  asm_memmove, %function
    .p2align 2
asm_memmove:
    cmp     x0, x1                      // dst == src?
    b.eq    .Lmv_ret                    // yes: nothing to do
    b.hi    .Lmv_backwards              // dst > src: may need a backward copy
    /* ---- dst < src: a forward copy is always overlap-safe -------------- */
    add     x3, x0, x2                  // x3 = dst + n
    cmp     x3, x1                      // dst + n <= src (fully disjoint)?
    b.ls    asm_memcpy                  // yes: the fast forward copy is safe
    mov     x5, x0                      // x5 = dest cursor
    mov     x6, x1                      // x6 = source cursor
    add     x7, x0, x2                  // x7 = dest + n (end)
.Lmv_fwd64:
    add     x3, x5, #64                 // x3 = end of the next 64-byte block
    cmp     x3, x7                      // does a full block still fit?
    b.hi    .Lmv_fwd_bytes              // no: finish byte-wise
    ldp     q0, q1, [x6]                // load 64 source bytes
    ldp     q2, q3, [x6, #32]           // load source bytes +32 .. +63
    stp     q0, q1, [x5]                // store 64 destination bytes
    stp     q2, q3, [x5, #32]           // store destination bytes +32 .. +63
    add     x5, x5, #64                 // advance the dest cursor
    add     x6, x6, #64                 // advance the source cursor
    b       .Lmv_fwd64                  // next block
.Lmv_fwd_bytes:
    cmp     x5, x7                      // copied everything?
    b.hs    .Lmv_ret                    // yes: return
    ldrb    w3, [x6], #1                // load one source byte, advance
    strb    w3, [x5], #1                // store one dest byte, advance
    b       .Lmv_fwd_bytes              // next byte
    /* ---- dst > src: maybe overlapping, copy strictly high to low ------- */
.Lmv_backwards:
    add     x3, x1, x2                  // x3 = src + n
    cmp     x0, x3                      // dst >= src + n (fully disjoint)?
    b.hs    asm_memcpy                  // yes: the fast forward copy is safe
    mov     x5, x0                      // x5 = dest cursor
    add     x5, x5, x2                  // x5 = dst + n (one past the end)
    mov     x6, x1                      // x6 = source cursor
    add     x6, x6, x2                  // x6 = src + n (one past the end)
.Lmv_bwd64:
    sub     x3, x5, #64                 // x3 = start of the next lower block
    cmp     x3, x0                      // still at or above dst?
    b.lo    .Lmv_bwd_bytes              // no: finish byte-wise
    sub     x5, x5, #64                 // step the dest cursor down
    sub     x6, x6, #64                 // step the source cursor down
    ldp     q0, q1, [x6]                // load 64 source bytes
    ldp     q2, q3, [x6, #32]           // load source bytes +32 .. +63
    stp     q0, q1, [x5]                // store 64 destination bytes
    stp     q2, q3, [x5, #32]           // store destination bytes +32 .. +63
    b       .Lmv_bwd64                  // next block
.Lmv_bwd_bytes:
    cmp     x5, x0                      // reached the destination start?
    b.eq    .Lmv_ret                    // yes: return
    sub     x5, x5, #1                  // step the dest cursor down
    sub     x6, x6, #1                  // step the source cursor down
    ldrb    w3, [x6]                    // load one source byte
    strb    w3, [x5]                    // store one dest byte
    b       .Lmv_bwd_bytes              // next byte
.Lmv_ret:
    ret                                 // return dst (x0)
    .size asm_memmove, .-asm_memmove

/*==============================================================================
 * void *asm_memset(void *dst, int c, size_t n)
 *------------------------------------------------------------------------------
 * Fills n bytes at dst with the low byte of c. Returns dst.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (void *)        - destination buffer start
 *   w1 = c   (int)           - fill value; only the low 8 bits are used
 *   x2 = n   (size_t)        - number of bytes to fill
 * Returns:
 *   x0 = dst (the original destination pointer)
 * Uses / clobbers:
 *   Writes x3..x5 and q0 (all caller-saved); x0 is returned unchanged.
 *============================================================================*/
    .globl asm_memset
    .type  asm_memset, %function
    .p2align 2
asm_memset:
    dup     v0.16b, w1                  // broadcast the fill byte to all 16 lanes
    cmp     x2, #32                     // n >= 32?
    b.hs    .Lset_ge32                  // yes: vector stores
    cmp     x2, #16                     // 16 <= n < 32?
    b.hs    .Lset_16_31                 // yes: two overlapping 16-byte stores
    cmp     x2, #8                      // 8 <= n < 16?
    b.hs    .Lset_8_15                  // yes: two overlapping 8-byte stores
    cmp     x2, #4                      // 4 <= n < 8?
    b.hs    .Lset_4_7                   // yes: two overlapping 4-byte stores
    cbz     x2, .Lset_done              // n == 0: nothing to do
    /* ---- 1..3 bytes: first and last, plus the middle when n == 3 -------- */
    strb    w1, [x0]                    // store byte 0
    sub     x3, x2, #1                  // x3 = n-1
    strb    w1, [x0, x3]                // store byte n-1
    cmp     x2, #3                      // exactly three bytes?
    b.ne    .Lset_done                  // no: 1 or 2 are already covered
    strb    w1, [x0, #1]                // store the middle byte
.Lset_done:
    ret                                 // return dst (x0)
    /* ---- 4 <= n < 8: two overlapping 4-byte stores ---------------------- */
.Lset_4_7:
    sub     x3, x2, #4                  // x3 = n-4
    str     s0, [x0]                    // store the first 4 bytes
    add     x4, x0, x3                  // x4 = &dst[n-4]
    str     s0, [x4]                    // store the last 4 bytes
    ret                                 // return dst (x0)
    /* ---- 8 <= n < 16: two overlapping 8-byte stores --------------------- */
.Lset_8_15:
    sub     x3, x2, #8                  // x3 = n-8
    str     d0, [x0]                    // store the first 8 bytes
    add     x4, x0, x3                  // x4 = &dst[n-8]
    str     d0, [x4]                    // store the last 8 bytes
    ret                                 // return dst (x0)
    /* ---- 16 <= n < 32: two overlapping 16-byte stores ------------------- */
.Lset_16_31:
    sub     x3, x2, #16                 // x3 = n-16
    str     q0, [x0]                    // store the first 16 bytes
    add     x4, x0, x3                  // x4 = &dst[n-16]
    str     q0, [x4]                    // store the last 16 bytes
    ret                                 // return dst (x0)
    /* ---- n >= 32: vectorised stores start here ------------------------- */
.Lset_ge32:
    add     x4, x0, x2                  // x4 = dst + n (one past the end)
    cmp     x2, #64                     // n >= 64?
    b.hs    .Lset_ge64                  // yes: 64-byte store loop
    /* ---- 32 <= n < 64: first 32 and last 32 overlap --------------------- */
    stp     q0, q0, [x0]                // store the first 32 bytes
    sub     x4, x4, #32                 // x4 = dst + n - 32
    stp     q0, q0, [x4]                // store the last 32 bytes
    ret                                 // return dst (x0)
    /* ---- n >= 64: store 64-byte blocks, then an overlapping final block - */
.Lset_ge64:
    mov     x5, x0                      // x5 = destination cursor
    sub     x4, x4, #64                 // x4 = dst + n - 64 (final block start)
.Lset_loop:
    stp     q0, q0, [x5]                // store destination bytes +0 .. +31
    stp     q0, q0, [x5, #32]           // store destination bytes +32 .. +63
    add     x5, x5, #64                 // advance the cursor
    cmp     x5, x4                      // reached the final block?
    b.lo    .Lset_loop                  // no: keep storing
    stp     q0, q0, [x4]                // overlapping final 32 bytes +0 .. +31
    stp     q0, q0, [x4, #32]           // overlapping final 32 bytes +32 .. +63
    ret                                 // return dst (x0)
    .size asm_memset, .-asm_memset

/*==============================================================================
 * void *asm_bzero(void *dst, size_t n)
 *------------------------------------------------------------------------------
 * Zeroes n bytes at dst. Returns dst. Tail-calls asm_memset with c == 0.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (void *)        - destination buffer start
 *   x1 = n   (size_t)        - number of bytes to zero
 * Returns:
 *   x0 = dst (the original destination pointer)
 * Uses / clobbers:
 *   Rewrites x1..x5 (x2 receives n) and q0 via asm_memset; x0 is preserved.
 *============================================================================*/
    .globl asm_bzero
    .type  asm_bzero, %function
    .p2align 2
asm_bzero:
    mov     x2, x1                      // third arg (n) = old second arg
    mov     x1, #0                      // fill byte = 0
    b       asm_memset                  // tail-call the shared fill
    .size asm_bzero, .-asm_bzero

/*==============================================================================
 * void asm_explicit_bzero(void *dst, size_t n)
 *------------------------------------------------------------------------------
 * Zeroes n bytes at dst, with stores the optimiser may not elide.  There is no
 * "memory clobber" directive available in raw assembly, so the guarantee comes
 * from this routine being a real out-of-line global symbol: the compiler treats
 * the call as opaque and cannot prove the stores dead, exactly as with libc's
 * explicit_bzero.  Tail-calls asm_memset with c == 0.
 *
 * Parameters (AAPCS64):
 *   x0 = dst (void *)        - destination buffer start
 *   x1 = n   (size_t)        - number of bytes to zero
 * Returns:
 *   none
 * Uses / clobbers:
 *   Rewrites x1..x5 (x2 receives n) and q0 via asm_memset; x0 is left as dst.
 *============================================================================*/
    .globl asm_explicit_bzero
    .type  asm_explicit_bzero, %function
    .p2align 2
asm_explicit_bzero:
    mov     x2, x1                      // third arg (n) = old second arg
    mov     x1, #0                      // fill byte = 0
    b       asm_memset                  // tail-call the shared fill
    .size asm_explicit_bzero, .-asm_explicit_bzero

/*==============================================================================
 * int asm_memcmp(const void *a, const void *b, size_t n)
 *------------------------------------------------------------------------------
 * Compares the first n bytes. Returns <0, 0 or >0 using unsigned byte values.
 *
 * Parameters (AAPCS64):
 *   x0 = a (const void *)    - first buffer start
 *   x1 = b (const void *)    - second buffer start
 *   x2 = n (size_t)          - number of bytes to compare
 * Returns:
 *   w0 = signed difference (a[i] - b[i]) at the first differing byte, or 0
 * Uses / clobbers:
 *   Writes x3..x7 and q0..q3 (all caller-saved).
 *============================================================================*/
    .globl asm_memcmp
    .type  asm_memcmp, %function
    .p2align 2
asm_memcmp:
    mov     x3, x0                      // x3 = cursor over a
    mov     x4, x1                      // x4 = cursor over b
.Lcmp_loop16:
    cmp     x2, #16                     // at least one full vector left?
    b.lo    .Lcmp_tail                  // no: finish with the scalar tail
    ld1     {v0.16b}, [x3], #16         // load 16 bytes of a, advance
    ld1     {v1.16b}, [x4], #16         // load 16 bytes of b, advance
    cmeq    v2.16b, v0.16b, v1.16b      // per-byte equality mask (0xFF == equal)
    uminv   b3, v2.16b                  // 0xFF only when all 16 bytes are equal
    umov    w5, v3.b[0]                 // move the summary byte to a GPR
    cmp     w5, #0xff                   // all 16 bytes equal?
    b.ne    .Lcmp_diff16                // no: locate the first difference
    sub     x2, x2, #16                 // consumed one full vector
    b       .Lcmp_loop16                // compare the next vector
.Lcmp_diff16:
    sub     x3, x3, #16                 // rewind a to the block start
    sub     x4, x4, #16                 // rewind b to the block start
.Lcmp_bytes:
    ldrb    w5, [x3], #1                // load one byte of a, advance
    ldrb    w6, [x4], #1                // load one byte of b, advance
    subs    w7, w5, w6                  // unsigned byte difference
    b.ne    .Lcmp_ret                   // differ: return the difference
    subs    x2, x2, #1                  // one fewer byte to compare
    b.ne    .Lcmp_bytes                 // keep comparing
    mov     w0, #0                      // defensive: all compared bytes equal
    ret                                 // return 0
.Lcmp_tail:
    cbz     x2, .Lcmp_equal             // nothing left: equal
    b       .Lcmp_bytes                 // byte-wise tail
.Lcmp_equal:
    mov     w0, #0                      // all compared bytes equal
    ret                                 // return 0
.Lcmp_ret:
    mov     w0, w7                      // return a - b as a signed int
    ret                                 // return the byte difference
    .size asm_memcmp, .-asm_memcmp

/*==============================================================================
 * void *asm_memchr(const void *s, int c, size_t n)
 *------------------------------------------------------------------------------
 * Returns a pointer to the first byte equal to (unsigned char)c within the
 * first n bytes, or NULL if there is none.  The vector loop only loads a full
 * 16-byte window while at least 16 bytes remain, so it never reads past s+n.
 *
 * Parameters (AAPCS64):
 *   x0 = s (const void *)    - buffer start
 *   w1 = c (int)             - byte value to search for (low 8 bits)
 *   x2 = n (size_t)          - number of bytes to scan
 * Returns:
 *   x0 = pointer to the first matching byte, or NULL
 * Uses / clobbers:
 *   Writes x3/x4 and q0..q2 (all caller-saved).
 *============================================================================*/
    .globl asm_memchr
    .type  asm_memchr, %function
    .p2align 2
asm_memchr:
    uxtb    w1, w1                      // keep only the low byte of c
    cbz     x2, .Lchr_null              // n == 0: cannot match
    dup     v0.16b, w1                  // broadcast the search byte
    mov     x3, x0                      // x3 = scan cursor
.Lchr_loop:
    cmp     x2, #16                     // a full vector left?
    b.lo    .Lchr_tail                  // no: scalar tail
    ld1     {v1.16b}, [x3]              // load 16 candidate bytes
    cmeq    v1.16b, v1.16b, v0.16b      // compare against c
    umaxv   b2, v1.16b                  // non-zero when any byte matched
    umov    w4, v2.b[0]                 // move the summary byte to a GPR
    cbnz    w4, .Lchr_found             // match in this vector
    add     x3, x3, #16                 // advance one vector
    sub     x2, x2, #16                 // consumed one vector
    b       .Lchr_loop                  // next vector
.Lchr_found:
    ldrb    w4, [x3]                    // scan the block for the first hit
    cmp     w4, w1                      // equal to c?
    b.eq    .Lchr_hit                   // yes: this is the first match
    add     x3, x3, #1                  // next byte
    b       .Lchr_found                 // keep scanning the block
.Lchr_tail:
    cbz     x2, .Lchr_null              // nothing left: no match
    ldrb    w4, [x3]                    // candidate byte
    cmp     w4, w1                      // equal to c?
    b.eq    .Lchr_hit                   // yes: return it
    add     x3, x3, #1                  // advance
    sub     x2, x2, #1                  // one fewer byte
    b       .Lchr_tail                  // continue
.Lchr_hit:
    mov     x0, x3                      // return pointer to the match
    ret                                 // return the match pointer
.Lchr_null:
    mov     x0, #0                      // return NULL
    ret                                 // return NULL
    .size asm_memchr, .-asm_memchr

/*==============================================================================
 * void *asm_memrchr(const void *s, int c, size_t n)
 *------------------------------------------------------------------------------
 * Returns a pointer to the last byte equal to (unsigned char)c within the
 * first n bytes, or NULL if there is none.  Blocks are scanned from the high
 * end down, and each vector load stays inside [s, s+n).
 *
 * Parameters (AAPCS64):
 *   x0 = s (const void *)    - buffer start
 *   w1 = c (int)             - byte value to search for (low 8 bits)
 *   x2 = n (size_t)          - number of bytes to scan
 * Returns:
 *   x0 = pointer to the last matching byte, or NULL
 * Uses / clobbers:
 *   Writes x3..x5 and q0..q2 (all caller-saved).
 *============================================================================*/
    .globl asm_memrchr
    .type  asm_memrchr, %function
    .p2align 2
asm_memrchr:
    uxtb    w1, w1                      // keep only the low byte of c
    cbz     x2, .Lrchr_null             // n == 0: cannot match
    dup     v0.16b, w1                  // broadcast the search byte
    add     x3, x0, x2                  // x3 = one past the last byte
.Lrchr_loop:
    cmp     x2, #16                     // a full vector left?
    b.lo    .Lrchr_tail                 // no: scalar tail
    sub     x3, x3, #16                 // step to the block start
    sub     x2, x2, #16                 // consumed one vector
    ld1     {v1.16b}, [x3]              // load 16 candidate bytes
    cmeq    v1.16b, v1.16b, v0.16b      // compare against c
    umaxv   b2, v1.16b                  // non-zero when any byte matched
    umov    w4, v2.b[0]                 // move the summary byte to a GPR
    cbz     w4, .Lrchr_loop             // no match: next lower block
    add     x5, x3, #15                 // scan this block from the top
.Lrchr_found:
    ldrb    w4, [x5]                    // candidate byte
    cmp     w4, w1                      // equal to c?
    b.eq    .Lrchr_hit                  // yes: highest match so far
    sub     x5, x5, #1                  // next lower byte
    b       .Lrchr_found                // keep scanning down
.Lrchr_hit:
    mov     x0, x5                      // return pointer to the match
    ret                                 // return the match pointer
.Lrchr_tail:
    cbz     x2, .Lrchr_null             // nothing left: no match
    sub     x5, x3, #1                  // last un-scanned byte
.Lrchr_tail_loop:
    ldrb    w4, [x5]                    // candidate byte
    cmp     w4, w1                      // equal to c?
    b.eq    .Lrchr_hit                  // yes: return it
    sub     x5, x5, #1                  // step down
    subs    x2, x2, #1                  // one fewer byte
    b.ne    .Lrchr_tail_loop            // continue
.Lrchr_null:
    mov     x0, #0                      // return NULL
    ret                                 // return NULL
    .size asm_memrchr, .-asm_memrchr

GNU_STACK_NOTE                          // mark the stack non-executable
