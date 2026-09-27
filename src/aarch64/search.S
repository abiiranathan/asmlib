/*==============================================================================
 * search.S - high-performance string/number searching (AArch64 / AAPCS64)
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * AArch64 port of src/search.asm. Implements:
 *
 *   char  *asm_strchr (const char *s, int c);
 *   char  *asm_strrchr(const char *s, int c);
 *   char  *asm_strstr (const char *hay, const char *needle);
 *   void  *asm_memmem (const void *hay, size_t hlen,
 *                      const void *needle, size_t nlen);
 *   size_t asm_strspn (const char *s, const char *accept);
 *   size_t asm_strcspn(const char *s, const char *accept);
 *   char  *asm_strpbrk(const char *s, const char *accept);
 *
 * asm_strchr performs a single NEON pass over 16-byte, naturally aligned
 * blocks that simultaneously test for the target byte and for the terminating
 * NUL, honouring whichever occurs first. Alignment keeps every load inside one
 * hardware page (4096 is a multiple of 16), so the scan never faults on an
 * unmapped page after the string.
 *
 * asm_strrchr reuses asm_strchr to locate the terminating NUL and then walks
 * backwards over the string body. asm_strstr reuses asm_strchr to measure both
 * strings and then delegates to asm_memmem. The accept-set routines build a
 * 256-byte membership table on the stack (see BUILD_ACCEPT_TABLE) so the scan
 * is a single linear pass.
 *
 * This port is deliberately self-contained: it calls only routines defined in
 * this file, so it can be linked and tested without the rest of the library.
 *============================================================================*/

#include "common_aarch64.inc"

    .text

/*==============================================================================
 * V_MASK - turn a 16-byte 0x00/0xFF NEON comparison result into a 16-bit mask
 *------------------------------------------------------------------------------
 * AArch64 has no pmovmskb, so the bit of each matching byte is gathered with
 * the classic "multiply by a magic constant" trick: masking the low bit of
 * every byte and multiplying by 0x0102040810204080 moves byte i's bit into bit
 * i of the top byte. Both 64-bit halves are packed into one 16-bit value.
 *
 * Parameters:
 *   vq = source vector holding 0x00 or 0xFF per byte
 *   d0 = destination 64-bit register (receives the 16-bit mask in bits 0..15)
 *   d1 = scratch 64-bit register
 * Reads / clobbers: d0, d1 and the fixed constants in x9/x10.
 *============================================================================*/
.macro V_MASK vq, d0, d1
    umov    \d0, \vq\().d[0]            /* low 64 bits of the comparison      */
    umov    \d1, \vq\().d[1]            /* high 64 bits of the comparison     */
    and     \d0, \d0, x9                /* keep bit 0 of every byte           */
    and     \d1, \d1, x9                /* keep bit 0 of every byte           */
    mul     \d0, \d0, x10               /* gather the low eight bits          */
    mul     \d1, \d1, x10               /* gather the high eight bits         */
    lsr     \d0, \d0, #56               /* move the gathered byte down        */
    lsr     \d1, \d1, #56               /* move the gathered byte down        */
    orr     \d0, \d0, \d1, lsl #8       /* bits 0..7 low, 8..15 high          */
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
    rbit    \dst, \src                  /* mirror so the low bit becomes high */
    clz     \dst, \dst                  /* count the leading zeroes          */
.endm

/*==============================================================================
 * char *asm_strchr(const char *s, int c)
 *------------------------------------------------------------------------------
 * Returns a pointer to the first occurrence of (char)c in s, including the
 * terminating NUL if c == 0, or NULL if the byte is not present.
 *
 * Parameters (AAPCS64):
 *   x0 = s (const char *)  - NUL-terminated string to scan
 *   w1 = c (int)           - byte value to find; only the low 8 bits are used
 * Returns:
 *   x0 = pointer to the first matching byte, or NULL when absent
 * Uses / clobbers:
 *   Reads x0/x1; writes x0..x7, x9, x10 and v0..v4. All are caller-saved; no
 *   callee-saved register is touched and no call is made.
 *============================================================================*/
    .globl asm_strchr
    .type  asm_strchr, %function
    .p2align 2
asm_strchr:
    /* ---- broadcast the search byte and build a zero vector ---- */
    dup     v0.16b, w1                  /* v0 = c in every byte               */
    eor     v1.16b, v1.16b, v1.16b      /* v1 = all zero                      */
    /* ---- constants for the byte -> bitmask gather ---- */
    movz    x9, #0x0101                 /* x9 = 0x0101010101010101            */
    movk    x9, #0x0101, lsl #16
    movk    x9, #0x0101, lsl #32
    movk    x9, #0x0101, lsl #48
    movz    x10, #0x4080                /* x10 = 0x0102040810204080           */
    movk    x10, #0x1020, lsl #16
    movk    x10, #0x0408, lsl #32
    movk    x10, #0x0102, lsl #48
    /* ---- page-safe aligned base plus the offset of s within it ---- */
    ubfx    x3, x0, #0, #4              /* x3 = s & 15                        */
    sub     x2, x0, x3                  /* x2 = base = s & ~15 (page safe)    */
    /* ---- head block: bytes before s are masked off with a shift ---- */
    ldr     q2, [x2]                    /* aligned, page-safe load            */
    cmeq    v3.16b, v2.16b, v0.16b      /* bytes equal to c                   */
    cmeq    v4.16b, v2.16b, v1.16b      /* NUL bytes                          */
    V_MASK  v3, x4, x5                  /* x4 = c mask (relative to base)     */
    V_MASK  v4, x6, x7                  /* x6 = NUL mask (relative to base)   */
    lsr     x4, x4, x3                  /* drop bytes before s               */
    lsr     x6, x6, x3                  /* drop bytes before s               */
    cbz     x4, .Lchr_head_no_c         /* no c at/after s: continue          */
    cbz     x6, .Lchr_head_only_c       /* c and no NUL: the match is valid   */
    /* ---- both present: whichever occurs first wins ---- */
    V_CTZ   x5, x4                      /* position of the first c            */
    V_CTZ   x7, x6                      /* position of the first NUL          */
    cmp     x5, x7
    b.hi    .Lchr_notfound              /* NUL precedes c: c is absent        */
.Lchr_head_hit:
    add     x0, x0, x5                  /* result = s + position              */
    ret
.Lchr_head_only_c:
    V_CTZ   x5, x4                      /* position of the only c match       */
    add     x0, x0, x5                  /* result = s + position              */
    ret
.Lchr_head_no_c:
    cbnz    x6, .Lchr_notfound          /* NUL with no c before it: absent    */
    add     x2, x2, #16                 /* advance to the next aligned block  */
    /* ---- aligned main scan: 16-byte page-safe blocks ---- */
.Lchr_loop:
    ldr     q2, [x2]                    /* aligned, page-safe load            */
    cmeq    v3.16b, v2.16b, v0.16b      /* bytes equal to c                   */
    cmeq    v4.16b, v2.16b, v1.16b      /* NUL bytes                          */
    V_MASK  v3, x4, x5                  /* c mask for this block              */
    V_MASK  v4, x6, x7                  /* NUL mask for this block            */
    cbz     x4, .Lchr_loop_no_c         /* no c in this block                 */
    cbz     x6, .Lchr_loop_found        /* c and no NUL: the match is valid   */
    /* ---- both present: whichever occurs first wins ---- */
    V_CTZ   x5, x4                      /* position of the first c            */
    V_CTZ   x7, x6                      /* position of the first NUL          */
    cmp     x5, x7
    b.hi    .Lchr_notfound              /* NUL precedes c: c is absent        */
    add     x0, x2, x5                  /* result = block + position          */
    ret
.Lchr_loop_found:
    V_CTZ   x5, x4                      /* position of the first c            */
    add     x0, x2, x5                  /* result = block + position          */
    ret
.Lchr_loop_no_c:
    cbnz    x6, .Lchr_notfound          /* NUL with no c: c is absent         */
    add     x2, x2, #16                 /* advance one aligned block          */
    b       .Lchr_loop
.Lchr_notfound:
    mov     x0, #0                      /* return NULL                        */
    ret
    .size asm_strchr, .-asm_strchr

/*==============================================================================
 * char *asm_strrchr(const char *s, int c)
 *------------------------------------------------------------------------------
 * Returns a pointer to the last occurrence of (char)c in s, including the
 * terminating NUL if c == 0, or NULL if the byte is not present.
 *
 * Parameters (AAPCS64):
 *   x0 = s (const char *)  - NUL-terminated string to scan
 *   w1 = c (int)           - byte value to find; only the low 8 bits are used
 * Returns:
 *   x0 = pointer to the last matching byte, or NULL when absent
 * Uses / clobbers:
 *   Preserves x19/x20. Calls asm_strchr (which clobbers x0..x10 and v0..v4).
 *   A scalar backward walk over the string body finds the last occurrence.
 *============================================================================*/
    .globl asm_strrchr
    .type  asm_strrchr, %function
    .p2align 2
asm_strrchr:
    /* ---- prologue: preserve state across the asm_strchr call ---- */
    stp     x19, x20, [sp, #-32]!       /* save callee-saved registers        */
    str     x30, [sp, #16]              /* save the link register             */
    mov     x19, x0                     /* x19 = s                            */
    uxtb    w20, w1                     /* w20 = c (only the low byte)        */
    mov     w1, #0                      /* search for the terminating NUL     */
    bl      asm_strchr                  /* x0 = pointer to the NUL            */
    mov     x2, x0                      /* x2 = NUL pointer                   */
    cbz     w20, .Lrr_nul               /* c == 0: report the NUL itself      */
    /* ---- walk backwards from the byte before the NUL ---- */
    sub     x3, x2, #1                  /* x3 = last character of the body    */
.Lrr_back:
    cmp     x3, x19                     /* walked off the start of s?         */
    b.lo    .Lrr_null                   /* yes: c is absent                   */
    ldrb    w4, [x3]                    /* next byte going backwards          */
    cmp     w4, w20                     /* equal to c?                        */
    b.eq    .Lrr_hit                    /* yes: this is the last occurrence   */
    sub     x3, x3, #1                  /* step one byte towards the start    */
    b       .Lrr_back
.Lrr_hit:
    mov     x0, x3                      /* return the matching address        */
    ldr     x30, [sp, #16]              /* restore the link register          */
    ldp     x19, x20, [sp], #32         /* restore callee-saved registers     */
    ret
.Lrr_nul:
    mov     x0, x2                      /* c == 0: pointer to the NUL         */
    ldr     x30, [sp, #16]              /* restore the link register          */
    ldp     x19, x20, [sp], #32         /* restore callee-saved registers     */
    ret
.Lrr_null:
    mov     x0, #0                      /* return NULL                        */
    ldr     x30, [sp, #16]              /* restore the link register          */
    ldp     x19, x20, [sp], #32         /* restore callee-saved registers     */
    ret
    .size asm_strrchr, .-asm_strrchr

/*==============================================================================
 * void *asm_memmem(const void *hay, size_t hlen,
 *                  const void *needle, size_t nlen)
 *------------------------------------------------------------------------------
 * Finds the first occurrence of needle[0..nlen) inside hay[0..hlen).
 * Returns the address or NULL. An empty needle returns hay.
 *
 * Parameters (AAPCS64):
 *   x0 = hay    (const void *) - buffer to search
 *   x1 = hlen   (size_t)       - number of bytes in hay
 *   x2 = needle (const void *) - bytes to find
 *   x3 = nlen   (size_t)       - number of bytes in needle
 * Returns:
 *   x0 = pointer to the first match, or NULL when there is none
 * Uses / clobbers:
 *   Reads/writes x0..x11 only; leaf function, no calls, no NEON. Reads are
 *   strictly bounded by hlen and nlen.
 *============================================================================*/
    .globl asm_memmem
    .type  asm_memmem, %function
    .p2align 2
asm_memmem:
    /* ---- length checks ---- */
    cbz     x3, .Lmm_hay                /* empty needle: match at hay         */
    cmp     x3, x1                      /* needle longer than haystack?       */
    b.hi    .Lmm_null                   /* yes: impossible                    */
    sub     x4, x1, x3                  /* x4 = last legal start offset       */
    mov     x5, #0                      /* x5 = candidate start offset i      */
    ldrb    w6, [x2]                    /* w6 = needle[0]                     */
    /* ---- outer loop over candidate start offsets ---- */
.Lmm_outer:
    cmp     x5, x4                      /* any candidate left?                */
    b.hi    .Lmm_null                   /* no: no match                       */
    ldrb    w7, [x0, x5]                /* hay[i]                             */
    cmp     w7, w6                      /* cheap prefilter: needle[0]?        */
    b.ne    .Lmm_next
    add     x10, x0, x5                 /* x10 = hay + i                      */
    mov     x8, #1                      /* x8 = next byte to compare          */
    /* ---- inner loop: verify the whole needle ---- */
.Lmm_inner:
    cmp     x8, x3                      /* compared all nlen bytes?           */
    b.hs    .Lmm_found                  /* yes: full match                    */
    ldrb    w9, [x10, x8]               /* hay[i + j]                         */
    ldrb    w11, [x2, x8]               /* needle[j]                          */
    cmp     w9, w11
    b.ne    .Lmm_next                   /* mismatch: try the next start       */
    add     x8, x8, #1
    b       .Lmm_inner
.Lmm_next:
    add     x5, x5, #1                  /* advance the candidate start        */
    b       .Lmm_outer
.Lmm_found:
    add     x0, x0, x5                  /* return the match address           */
    ret
.Lmm_hay:
    ret                                 /* empty needle: hay is already in x0 */
.Lmm_null:
    mov     x0, #0                      /* return NULL                        */
    ret
    .size asm_memmem, .-asm_memmem

/*==============================================================================
 * char *asm_strstr(const char *hay, const char *needle)
 *------------------------------------------------------------------------------
 * Finds the first occurrence of the NUL-terminated needle inside hay.
 * Returns the address or NULL. An empty needle returns hay.
 *
 * Parameters (AAPCS64):
 *   x0 = hay    (const char *) - NUL-terminated string to search
 *   x1 = needle (const char *) - NUL-terminated substring to find
 * Returns:
 *   x0 = pointer to the first match, or NULL when there is none
 * Uses / clobbers:
 *   Preserves x19/x20/x21. Measures both strings with asm_strchr (strlen is
 *   simply the distance to the NUL), then delegates to asm_memmem; a
 *   one-character needle goes straight to asm_strchr.
 *============================================================================*/
    .globl asm_strstr
    .type  asm_strstr, %function
    .p2align 2
asm_strstr:
    /* ---- prologue: preserve state across the calls ---- */
    stp     x19, x20, [sp, #-32]!       /* save callee-saved registers        */
    stp     x21, x30, [sp, #16]         /* save x21 and the link register     */
    mov     x19, x0                     /* x19 = hay                          */
    mov     x20, x1                     /* x20 = needle                       */
    /* ---- classify the needle by its first bytes ---- */
    ldrb    w2, [x20]                   /* needle[0]                          */
    cbz     w2, .Lss_empty              /* empty needle: match at hay         */
    ldrb    w3, [x20, #1]               /* needle[1]                          */
    cbz     w3, .Lss_one                /* one-character needle               */
    /* ---- general case: hlen and nlen, then memmem ---- */
    mov     x0, x19                     /* strlen(hay)                        */
    mov     w1, #0
    bl      asm_strchr                  /* x0 = pointer to the NUL            */
    sub     x21, x0, x19                /* x21 = hlen                         */
    mov     x0, x20                     /* strlen(needle)                     */
    mov     w1, #0
    bl      asm_strchr                  /* x0 = pointer to the NUL            */
    sub     x3, x0, x20                 /* x3 = nlen                          */
    mov     x0, x19                     /* first arg to memmem (hay)          */
    mov     x1, x21                     /* second arg to memmem (hlen)        */
    mov     x2, x20                     /* third arg to memmem (needle)       */
    bl      asm_memmem                  /* x0 = result                        */
    /* ---- epilogue ---- */
    ldp     x21, x30, [sp, #16]         /* restore x21 and the link register  */
    ldp     x19, x20, [sp], #32         /* restore callee-saved registers     */
    ret
.Lss_empty:
    mov     x0, x19                     /* empty needle matches at hay        */
    ldp     x21, x30, [sp, #16]
    ldp     x19, x20, [sp], #32
    ret
.Lss_one:
    mov     x0, x19                     /* one byte: a plain strchr suffices  */
    mov     w1, w2
    bl      asm_strchr
    ldp     x21, x30, [sp, #16]
    ldp     x19, x20, [sp], #32
    ret
    .size asm_strstr, .-asm_strstr

/*==============================================================================
 * BUILD_ACCEPT_TABLE - build a 256-byte membership table on the stack
 *------------------------------------------------------------------------------
 * Zero the 256-byte buffer that starts at the current stack pointer and then
 * set table[c] = 1 for every byte c listed in the NUL-terminated accept
 * string, so the span routines can test membership with one indexed load.
 *
 * Parameters:
 *   x1 = accept (const char *) - NUL-terminated byte set
 *   sp = base of the caller's 256-byte scratch area
 * Registers / side effects:
 *   Clobbers x3, x4, x5 and v0; writes into [sp, sp+256). The table is only
 *   valid while the caller keeps the stack allocation that holds it.
 *============================================================================*/
.macro BUILD_ACCEPT_TABLE
    movi    v0.16b, #0                  /* v0 = all zero                      */
    stp     q0, q0, [sp, #0]            /* zero the table with 32-byte stores */
    stp     q0, q0, [sp, #32]
    stp     q0, q0, [sp, #64]
    stp     q0, q0, [sp, #96]
    stp     q0, q0, [sp, #128]
    stp     q0, q0, [sp, #160]
    stp     q0, q0, [sp, #192]
    stp     q0, q0, [sp, #224]
    mov     x3, x1                      /* x3 = accept pointer                */
1:  ldrb    w4, [x3], #1                /* next accept byte (post-increment)  */
    cbz     w4, 2f                      /* end of accept string?              */
    mov     w5, #1
    strb    w5, [sp, x4]                /* mark byte as a member              */
    b       1b
2:
.endm

/*==============================================================================
 * size_t asm_strspn(const char *s, const char *accept)
 *------------------------------------------------------------------------------
 * Length of the initial segment of s made only of bytes from accept.
 *
 * Parameters (AAPCS64):
 *   x0 = s      (const char *) - string to scan
 *   x1 = accept (const char *) - set of accepted bytes
 * Returns:
 *   x0 = length of the initial run of bytes that are in accept
 * Uses / clobbers:
 *   Reserves a 256-byte stack table via BUILD_ACCEPT_TABLE (clobbering
 *   x3/x4/x5/v0 and that scratch area). Leaf function, no calls.
 *============================================================================*/
    .globl asm_strspn
    .type  asm_strspn, %function
    .p2align 2
asm_strspn:
    sub     sp, sp, #256                /* scratch membership table           */
    BUILD_ACCEPT_TABLE                  /* fill [sp, sp+256)                  */
    mov     x2, x0                      /* x2 = scan pointer                  */
    mov     x6, #0                      /* x6 = count                         */
    /* ---- table-driven scan of s ---- */
.Lsp_scan:
    ldrb    w4, [x2]                    /* next source byte                   */
    cbz     w4, .Lsp_done               /* NUL: end of segment                */
    ldrb    w5, [sp, x4]                /* byte a member of accept?           */
    cbz     w5, .Lsp_done               /* no: stop                           */
    add     x2, x2, #1                  /* advance                            */
    add     x6, x6, #1                  /* count a byte                       */
    b       .Lsp_scan
.Lsp_done:
    mov     x0, x6                      /* return the length                  */
    add     sp, sp, #256                /* release the membership table       */
    ret
    .size asm_strspn, .-asm_strspn

/*==============================================================================
 * size_t asm_strcspn(const char *s, const char *accept)
 *------------------------------------------------------------------------------
 * Length of the initial segment of s made only of bytes NOT in accept.
 *
 * Parameters (AAPCS64):
 *   x0 = s      (const char *) - string to scan
 *   x1 = accept (const char *) - set of rejected bytes
 * Returns:
 *   x0 = length of the initial run of bytes that are not in accept
 * Uses / clobbers:
 *   Reserves a 256-byte stack table via BUILD_ACCEPT_TABLE (clobbering
 *   x3/x4/x5/v0 and that scratch area). Leaf function, no calls.
 *============================================================================*/
    .globl asm_strcspn
    .type  asm_strcspn, %function
    .p2align 2
asm_strcspn:
    sub     sp, sp, #256                /* scratch membership table           */
    BUILD_ACCEPT_TABLE                  /* fill [sp, sp+256)                  */
    mov     x2, x0                      /* x2 = scan pointer                  */
    mov     x6, #0                      /* x6 = count                         */
    /* ---- table-driven scan of s ---- */
.Lsc_scan:
    ldrb    w4, [x2]                    /* next source byte                   */
    cbz     w4, .Lsc_done               /* NUL: end of segment                */
    ldrb    w5, [sp, x4]                /* byte a member of accept?           */
    cbnz    w5, .Lsc_done               /* yes: stop                          */
    add     x2, x2, #1                  /* advance                            */
    add     x6, x6, #1                  /* count a byte                       */
    b       .Lsc_scan
.Lsc_done:
    mov     x0, x6                      /* return the length                  */
    add     sp, sp, #256                /* release the membership table       */
    ret
    .size asm_strcspn, .-asm_strcspn

/*==============================================================================
 * char *asm_strpbrk(const char *s, const char *accept)
 *------------------------------------------------------------------------------
 * Returns a pointer to the first byte of s that also occurs in accept, or
 * NULL if there is none.
 *
 * Parameters (AAPCS64):
 *   x0 = s      (const char *) - string to scan
 *   x1 = accept (const char *) - set of bytes to look for
 * Returns:
 *   x0 = pointer to the first matching byte, or NULL when there is none
 * Uses / clobbers:
 *   Reserves a 256-byte stack table via BUILD_ACCEPT_TABLE (clobbering
 *   x3/x4/x5/v0 and that scratch area). Leaf function, no calls.
 *============================================================================*/
    .globl asm_strpbrk
    .type  asm_strpbrk, %function
    .p2align 2
asm_strpbrk:
    sub     sp, sp, #256                /* scratch membership table           */
    BUILD_ACCEPT_TABLE                  /* fill [sp, sp+256)                  */
    mov     x2, x0                      /* x2 = scan pointer                  */
    /* ---- table-driven scan of s ---- */
.Lpb_scan:
    ldrb    w4, [x2]                    /* next source byte                   */
    cbz     w4, .Lpb_null               /* NUL: no byte from accept found     */
    ldrb    w5, [sp, x4]                /* byte a member of accept?           */
    cbnz    w5, .Lpb_found              /* yes: report this address           */
    add     x2, x2, #1                  /* advance                            */
    b       .Lpb_scan
.Lpb_found:
    mov     x0, x2                      /* return this address                */
    add     sp, sp, #256                /* release the membership table       */
    ret
.Lpb_null:
    mov     x0, #0                      /* return NULL                        */
    add     sp, sp, #256                /* release the membership table       */
    ret
    .size asm_strpbrk, .-asm_strpbrk

GNU_STACK_NOTE
