/*==============================================================================
 * format.S - fast integer-to-string conversion (AArch64)
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * AArch64 port of src/format.asm. Bounded integer formatters:
 *
 *   size_t asm_u64toa      (uint64_t v, char *buf, size_t cap);
 *   size_t asm_i64toa      (int64_t  v, char *buf, size_t cap);
 *   size_t asm_u64toa_base (uint64_t v, char *buf, size_t cap, unsigned base);
 *   size_t asm_u64tohex    (uint64_t v, char *buf, size_t cap, int uppercase);
 *
 * The full formatted-output engine (asm_snprintf and the rest of the printf
 * family, including floating point) is the portable C implementation in
 * src/libc/printf.c, linked into every backend so behaviour is identical.
 *============================================================================*/

#include "common_aarch64.inc"

    .text

/*==============================================================================
 * internal: L_gen_digits
 *------------------------------------------------------------------------------
 * Generate the digits of x0 in base x1, writing backwards from x3, and return
 * the start pointer and length. x2 != 0 selects uppercase letters.
 *
 * Out: x10 = first digit, x11 = count
 * Clobbers: x0, x4, x5, x9
 *============================================================================*/
    .type  L_gen_digits, %function
    .p2align 2
L_gen_digits:
    cmp     x1, #10                     /* hot bases avoid the divider      */
    b.eq    .Lgd_dec
    cmp     x1, #16
    b.eq    .Lgd_hex
    cmp     x1, #8
    b.eq    .Lgd_oct
    b       .Lgd_generic
    /* ---- decimal: fixed-chunk forward writer (no loop, no udiv) ---- */
.Lgd_dec:
    sub     x1, x3, #24                 /* scratch start (20 digits max)    */
    str     x30, [sp, #-16]!
    str     x1, [sp, #-16]!
    bl      L_dec_forward               /* x0 = value, x1 = end             */
    ldr     x12, [sp], #16
    sub     x11, x1, x12
    mov     x10, x12
    ldr     x30, [sp], #16
    ret
    /* ---- hexadecimal ---- */
.Lgd_hex:
    mov     x9, x3
    adrp    x6, L_hexdig_lc
    add     x6, x6, :lo12:L_hexdig_lc
    cbz     x2, .Lgd_hex_go
    adrp    x6, L_hexdig_uc
    add     x6, x6, :lo12:L_hexdig_uc
.Lgd_hex_go:
    mov     x11, #0
    cbnz    x0, .Lgd_hex_loop
    sub     x9, x9, #1
    mov     w8, #48
    strb    w8, [x9]
    mov     x11, #1
    mov     x10, x9
    ret
.Lgd_hex_loop:
    and     x5, x0, #15
    ldrb    w8, [x6, x5]
    sub     x9, x9, #1
    strb    w8, [x9]
    add     x11, x11, #1
    lsr     x0, x0, #4
    cbnz    x0, .Lgd_hex_loop
    mov     x10, x9
    ret
    /* ---- octal ---- */
.Lgd_oct:
    mov     x9, x3
    adrp    x6, L_digits_lc
    add     x6, x6, :lo12:L_digits_lc
    mov     x11, #0
    cbnz    x0, .Lgd_oct_loop
    sub     x9, x9, #1
    mov     w8, #48
    strb    w8, [x9]
    mov     x11, #1
    mov     x10, x9
    ret
.Lgd_oct_loop:
    and     x5, x0, #7
    ldrb    w8, [x6, x5]
    sub     x9, x9, #1
    strb    w8, [x9]
    add     x11, x11, #1
    lsr     x0, x0, #3
    cbnz    x0, .Lgd_oct_loop
    mov     x10, x9
    ret
    /* ---- general base: hardware divide ---- */
.Lgd_generic:
    mov     x9, x3                      /* write cursor = end               */
    mov     x11, #0                     /* digit count                      */
.Lgd_loop:
    udiv    x4, x0, x1                  /* x4 = quotient                    */
    msub    x5, x4, x1, x0              /* x5 = remainder                   */
    cmp     x5, #9
    b.hi    .Lgd_alpha
    add     x5, x5, #48                 /* '0'                              */
    b       .Lgd_store
.Lgd_alpha:
    add     x5, x5, #87                 /* 'a' - 10                         */
    cbz     x2, .Lgd_store
    sub     x5, x5, #32                 /* fold to 'A'..'Z'                 */
.Lgd_store:
    sub     x9, x9, #1
    strb    w5, [x9]
    add     x11, x11, #1
    mov     x0, x4
    cbnz    x0, .Lgd_loop
    mov     x10, x9
    ret
    .size L_gen_digits, .-L_gen_digits

/*==============================================================================
 * internal: L_dec_forward(x0 = value, x1 = dst) -> x1 = end
 *------------------------------------------------------------------------------
 * Write the decimal digits of x0 forward with no loop: the magnitude selects a
 * fixed-chunk path built from a 200-byte two-digit table and reciprocal
 * multiplies. Callers must guarantee at least 20 writable bytes at x1; the
 * write is exact (no padding) and leaves x1 one past the last digit.
 *
 * Clobbers x0..x7, x9, x10, x12, and x30 via nested calls (saved here). The
 * digit-pair table lives in x10 and is untouched by the leaf helpers.
 *============================================================================*/
    .type  L_dec_forward, %function
    .p2align 2
L_dec_forward:
    str     x30, [sp, #-16]!
    adrp    x10, L_dec_pairs
    add     x10, x10, :lo12:L_dec_pairs
    mov     x8, #1
    lsl     x8, x8, #32
    sub     x8, x8, #1                  /* 0xFFFFFFFF                       */
    cmp     x0, x8
    b.hi    .Ldf_big
    bl      L_u32_to_str
    ldr     x30, [sp], #16
    ret
.Ldf_big:
    ldr     x9, =10000000000000000
    cmp     x0, x9
    b.hs    .Ldf_huge
    /* 9..16 digits: hi64 = v/1e8, lo32 = v%1e8 */
    ldr     x9, =0xabcc77118461cefd
    umulh   x2, x0, x9
    lsr     x2, x2, #26                 /* hi64                             */
    ldr     x3, =100000000
    msub    x3, x2, x3, x0              /* lo32                             */
    mov     x0, x2
    str     x3, [sp, #-16]!
    bl      L_u32_to_str
    ldr     x0, [sp], #16
    bl      L_put8
    ldr     x30, [sp], #16
    ret
.Ldf_huge:
    /* 17..20 digits: split off v/1e16, then 1e8 again */
    ldr     x9, =0x39a5652fb1137857
    umulh   x2, x0, x9
    lsr     x2, x2, #51                 /* hi_hi32                          */
    ldr     x9, =10000000000000000
    msub    x3, x2, x9, x0              /* rem16                            */
    mov     x0, x2
    str     x3, [sp, #-16]!
    bl      L_u32_to_str
    ldr     x3, [sp], #16               /* rem16                            */
    ldr     x9, =0xabcc77118461cefd
    umulh   x2, x3, x9
    lsr     x2, x2, #26                 /* hi_lo32                          */
    ldr     x4, =100000000
    msub    x3, x2, x4, x3              /* lo32                             */
    str     x3, [sp, #-16]!
    mov     x0, x2
    bl      L_put8
    ldr     x0, [sp], #16
    bl      L_put8
    ldr     x30, [sp], #16
    ret
    .size L_dec_forward, .-L_dec_forward

/*==============================================================================
 * internal: L_u32_to_str(x0 = value 0..2^32-1, x1 = dst)
 *------------------------------------------------------------------------------
 * Most significant chunk first, chunk size chosen from the magnitude; recurses
 * once for the 5..8 digit case.
 *============================================================================*/
    .type  L_u32_to_str, %function
    .p2align 2
L_u32_to_str:
    str     x30, [sp, #-16]!
    mov     w2, #100
    cmp     w0, w2
    b.lo    .Lu_lt100
    mov     w2, #10000
    cmp     w0, w2
    b.lo    .Lu_lt1e4
    ldr     w2, =100000000
    cmp     w0, w2
    b.lo    .Lu_lt1e8
    /* 9..10 digits */
    ldr     w2, =1441151881
    umull   x3, w0, w2
    lsr     x3, x3, #57                 /* hi                               */
    ldr     w4, =100000000
    msub    w5, w3, w4, w0              /* lo                               */
    mov     w0, w3
    str     x5, [sp, #-16]!
    bl      L_write_tail2
    ldr     x0, [sp], #16
    bl      L_put8
    ldr     x30, [sp], #16
    ret
.Lu_lt1e8:
    /* 5..8 digits */
    ldr     w2, =3518437209
    umull   x3, w0, w2
    lsr     x3, x3, #45                 /* hi                               */
    mov     w4, #10000
    msub    w5, w3, w4, w0              /* lo                               */
    mov     w0, w3
    str     x5, [sp, #-16]!
    bl      L_u32_to_str
    ldr     x0, [sp], #16
    bl      L_put4
    ldr     x30, [sp], #16
    ret
.Lu_lt1e4:
    /* 3..4 digits */
    ldr     w2, =1374389535
    umull   x3, w0, w2
    lsr     x3, x3, #37                 /* q                                */
    mov     w4, #100
    msub    w5, w3, w4, w0              /* r                                */
    mov     w0, w3
    str     x5, [sp, #-16]!
    bl      L_write_tail2
    ldr     x0, [sp], #16
    bl      L_put2
    ldr     x30, [sp], #16
    ret
.Lu_lt100:
    bl      L_write_tail2
    ldr     x30, [sp], #16
    ret
    .size L_u32_to_str, .-L_u32_to_str

/*==============================================================================
 * internal: L_write_tail2(w0 = 0..99) -> one or two digits at x1
 *============================================================================*/
    .type  L_write_tail2, %function
    .p2align 2
L_write_tail2:
    cmp     w0, #10
    b.hs    .Lwt_two
    add     w2, w0, #48
    strb    w2, [x1], #1
    ret
.Lwt_two:
    b       L_put2
    .size L_write_tail2, .-L_write_tail2

/*==============================================================================
 * internal: L_put2(w0 = 0..99) -> two digits at x1
 *============================================================================*/
    .type  L_put2, %function
    .p2align 2
L_put2:
    ldrh    w2, [x10, x0, lsl #1]
    strh    w2, [x1], #2
    ret
    .size L_put2, .-L_put2

/*==============================================================================
 * internal: L_put4(w0 = 0..9999) -> four digits at x1
 *============================================================================*/
    .type  L_put4, %function
    .p2align 2
L_put4:
    ldr     w2, =1374389535
    umull   x3, w0, w2
    lsr     x3, x3, #37                 /* q                                */
    mov     w4, #100
    msub    w5, w3, w4, w0              /* r                                */
    ldrh    w6, [x10, x3, lsl #1]
    strh    w6, [x1], #2
    ldrh    w6, [x10, x5, lsl #1]
    strh    w6, [x1], #2
    ret
    .size L_put4, .-L_put4

/*==============================================================================
 * internal: L_put8(w0 = 0..99999999) -> eight digits at x1
 *============================================================================*/
    .type  L_put8, %function
    .p2align 2
L_put8:
    str     x30, [sp, #-16]!
    ldr     w2, =3518437209
    umull   x3, w0, w2
    lsr     x3, x3, #45                 /* hi                               */
    mov     w4, #10000
    msub    w5, w3, w4, w0              /* lo                               */
    mov     w0, w3
    str     x5, [sp, #-16]!
    bl      L_put4
    ldr     x0, [sp], #16
    bl      L_put4
    ldr     x30, [sp], #16
    ret
    .size L_put8, .-L_put8

/*==============================================================================
 * internal: L_utoa_base_case
 *------------------------------------------------------------------------------
 * In:  x0 = value, x1 = buf, x2 = cap, x3 = base, x4 = uppercase
 * Out: x0 = full length (excluding NUL)
 *============================================================================*/
    .type  L_utoa_base_case, %function
    .p2align 2
L_utoa_base_case:
    stp     x19, x20, [sp, #-16]!
    stp     x21, x30, [sp, #-16]!
    sub     sp, sp, #80
    mov     x19, x1                     /* buf                              */
    mov     x20, x2                     /* cap                              */
    cmp     x3, #2
    b.lo    .Lub_bad
    cmp     x3, #36
    b.hi    .Lub_bad
    add     x9, sp, #80                 /* scratch end                      */
    mov     x10, #0
    mov     x11, x3
    mov     x12, x4
.Lub_loop:
    udiv    x4, x0, x11
    msub    x5, x4, x11, x0
    cmp     x5, #9
    b.hi    .Lub_alpha
    add     x5, x5, #48
    b       .Lub_store
.Lub_alpha:
    add     x5, x5, #87
    cbz     x12, .Lub_store
    sub     x5, x5, #32
.Lub_store:
    sub     x9, x9, #1
    strb    w5, [x9]
    add     x10, x10, #1
    mov     x0, x4
    cbnz    x0, .Lub_loop
    cbz     x20, .Lub_out
    sub     x13, x20, #1
    cmp     x13, x10
    csel    x13, x13, x10, ls
    mov     x14, x9
    mov     x15, x19
.Lub_copy:
    cbz     x13, .Lub_term
    ldrb    w16, [x14], #1
    strb    w16, [x15], #1
    sub     x13, x13, #1
    b       .Lub_copy
.Lub_term:
    strb    wzr, [x15]
.Lub_out:
    mov     x0, x10
    add     sp, sp, #80
    ldp     x21, x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
.Lub_bad:
    cbz     x20, .Lub_badret
    strb    wzr, [x19]
.Lub_badret:
    mov     x0, #0
    add     sp, sp, #80
    ldp     x21, x30, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size L_utoa_base_case, .-L_utoa_base_case

/*==============================================================================
 * size_t asm_u64toa(uint64_t value, char *buf, size_t cap)
 *============================================================================*/
    .globl asm_u64toa
    .type  asm_u64toa, %function
    .p2align 2
asm_u64toa:
    cmp     x2, #21                     /* 20 digits + NUL fits?            */
    b.lo    .Lau_small
    str     x30, [sp, #-16]!
    str     x1, [sp, #-16]!             /* remember buf                     */
    bl      L_dec_forward               /* x0 = value, x1 = end             */
    strb    wzr, [x1]
    ldr     x9, [sp], #16
    sub     x0, x1, x9
    ldr     x30, [sp], #16
    ret
.Lau_small:
    mov     x3, #10
    mov     x4, #0
    b       L_utoa_base_case
    .size asm_u64toa, .-asm_u64toa

/*==============================================================================
 * size_t asm_u64toa_base(uint64_t value, char *buf, size_t cap, unsigned base)
 *============================================================================*/
    .globl asm_u64toa_base
    .type  asm_u64toa_base, %function
    .p2align 2
asm_u64toa_base:
    mov     x4, #0
    b       L_utoa_base_case
    .size asm_u64toa_base, .-asm_u64toa_base

/*==============================================================================
 * size_t asm_u64tohex(uint64_t value, char *buf, size_t cap, int uppercase)
 *============================================================================*/
    .globl asm_u64tohex
    .type  asm_u64tohex, %function
    .p2align 2
asm_u64tohex:
    mov     x4, x3
    mov     x3, #16
    b       L_utoa_base_case
    .size asm_u64tohex, .-asm_u64tohex

/*==============================================================================
 * size_t asm_i64toa(int64_t value, char *buf, size_t cap)
 *============================================================================*/
    .globl asm_i64toa
    .type  asm_i64toa, %function
    .p2align 2
asm_i64toa:
    cmp     x2, #22                     /* '-' + 20 digits + NUL fits?      */
    b.lo    L_i64toa_small
    str     x30, [sp, #-16]!
    str     x1, [sp, #-16]!             /* remember buf                     */
    cmp     x0, #0
    b.ge    .Lid_pos
    neg     x0, x0
    mov     w9, #45
    strb    w9, [x1], #1
.Lid_pos:
    bl      L_dec_forward               /* x0 = magnitude, x1 = end         */
    strb    wzr, [x1]
    ldr     x9, [sp], #16
    sub     x0, x1, x9
    ldr     x30, [sp], #16
    ret

/* ---- bounded fallback: format into scratch, then copy what fits ---- */
L_i64toa_small:
    stp     x19, x20, [sp, #-16]!
    stp     x21, x22, [sp, #-16]!
    stp     x23, x30, [sp, #-16]!
    sub     sp, sp, #96
    mov     x19, x1                     /* buf                              */
    mov     x20, x2                     /* cap                              */
    mov     x22, #0                     /* sign length                      */
    mov     x21, x0
    cmp     x21, #0
    b.ge    .Li_pos
    neg     x21, x21
    mov     x22, #1
.Li_pos:
    add     x9, sp, #96
    mov     x10, #0
    mov     x11, #10
.Li_loop:
    udiv    x4, x21, x11
    msub    x5, x4, x11, x21
    add     x5, x5, #48
    sub     x9, x9, #1
    strb    w5, [x9]
    add     x10, x10, #1
    mov     x21, x4
    cbnz    x21, .Li_loop
    add     x23, x10, x22               /* full length                      */
    cbz     x20, .Li_out
    sub     x13, x20, #1
    cbz     x22, .Li_nosign
    cbz     x13, .Li_nosign
    mov     w14, #45
    strb    w14, [x19], #1
    sub     x13, x13, #1
.Li_nosign:
    cmp     x13, x10
    csel    x13, x13, x10, ls
    mov     x14, x9
    mov     x15, x19
.Li_copy:
    cbz     x13, .Li_term
    ldrb    w16, [x14], #1
    strb    w16, [x15], #1
    sub     x13, x13, #1
    b       .Li_copy
.Li_term:
    strb    wzr, [x15]
.Li_out:
    mov     x0, x23
    add     sp, sp, #96
    ldp     x23, x30, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ret
    .size asm_i64toa, .-asm_i64toa

    .section .rodata
L_nullstr:
    .asciz  "(null)"
L_nilstr:
    .asciz  "(nil)"
L_hexprefix:
    .asciz  "0x"
L_digits_lc:
    .asciz  "0123456789"
L_hexdig_lc:
    .asciz  "0123456789abcdef"
L_hexdig_uc:
    .asciz  "0123456789ABCDEF"
    .align  4
L_dec_pairs:
    .set    i, 0
    .rept   100
    .byte   48 + (i / 10), 48 + (i % 10)
    .set    i, i + 1
    .endr

GNU_STACK_NOTE
