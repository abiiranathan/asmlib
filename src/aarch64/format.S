/*==============================================================================
 * format.S - fast integer-to-string conversion and a minimal snprintf (AArch64)
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
 * and the small snprintf replacement:
 *
 *   int asm_snprintf(char *dst, size_t size, const char *fmt, ...);
 *
 * supporting %%, %c, %s, %p, %d, %i, %u, %x, %X and %o with the '-'/'0' flags,
 * a decimal width and the l/ll length modifiers; see include/asmlib.h for the
 * exact contract. Not a full printf: no floating point, precision, '*', locale
 * or %n.
 *
 * AAPCS64 notes: arguments arrive in x0..x7 (so the first vararg is x3) and the
 * result leaves in x0; x19..x28 and x29/x30 are callee-saved. The formatter
 * keeps its sink (cursor, remaining, count) and parse state in x19..x27, the
 * saved vararg registers in a stack save area addressed by x28, and the later
 * stack varargs by x24. Internal helpers are leaf routines except the two emit
 * helpers, which stash x30 in a spare stack slot.
 *============================================================================*/

#include "common_aarch64.inc"

/* asm_snprintf stack frame (sp-relative; sp is fixed after the prologue). */
#define ARG0      0             /* saved varargs x3..x7                     */
#define ARG1      8
#define ARG2      16
#define ARG3      24
#define ARG4      32
#define SCRATCH   40            /* 72-byte digit scratch (40..111)          */
#define SCRATCH_END 112
#define PRE_PTR   112
#define PRE_LEN   120
#define DIG_PTR   128
#define DIG_LEN   136
#define PAD       144
#define LR_SAVE   152
#define SIGN      160

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
 * internal: L_nextarg -> x0
 *------------------------------------------------------------------------------
 * Return the next integer vararg slot: x3..x7 from the save area while they
 * last, then the stacked arguments. Every slot is 8 bytes.
 * Clobbers: x0
 *============================================================================*/
    .type  L_nextarg, %function
    .p2align 2
L_nextarg:
    cmp     x23, #5
    b.hs    .Lna_stack
    ldr     x0, [x28, x23, lsl #3]
    add     x23, x23, #1
    ret
.Lna_stack:
    ldr     x0, [x24]
    add     x24, x24, #8
    ret
    .size L_nextarg, .-L_nextarg

/*==============================================================================
 * internal: L_putc(w9 = byte)
 *------------------------------------------------------------------------------
 * Append one byte, counting it even when the buffer is full. One byte stays
 * reserved for the NUL.
 *============================================================================*/
    .type  L_putc, %function
    .p2align 2
L_putc:
    add     x21, x21, #1
    cmp     x20, #2
    b.lo    .Lpc_ret
    strb    w9, [x19], #1
    sub     x20, x20, #1
.Lpc_ret:
    ret
    .size L_putc, .-L_putc

/*==============================================================================
 * internal: L_putn(x9 = src, x10 = len)
 *------------------------------------------------------------------------------
 * Append len bytes, counting all of them, storing only what fits.
 * Clobbers: x9, x10, x11, x12
 *============================================================================*/
    .type  L_putn, %function
    .p2align 2
L_putn:
    add     x21, x21, x10
    cmp     x20, #2
    b.lo    .Lpn_ret
    sub     x11, x20, #1                /* capacity past the NUL            */
    cmp     x10, x11
    csel    x10, x10, x11, ls           /* x10 = min(len, capacity)         */
    sub     x20, x20, x10
.Lpn_loop:
    cbz     x10, .Lpn_ret
    ldrb    w12, [x9], #1
    strb    w12, [x19], #1
    sub     x10, x10, #1
    b       .Lpn_loop
.Lpn_ret:
    ret
    .size L_putn, .-L_putn

/*==============================================================================
 * internal: L_putrep(w9 = byte, x10 = count)
 *------------------------------------------------------------------------------
 * Append count copies of a byte, counting all of them, storing what fits.
 * Clobbers: x10, x11
 *============================================================================*/
    .type  L_putrep, %function
    .p2align 2
L_putrep:
    add     x21, x21, x10
    cmp     x20, #2
    b.lo    .Lpr_ret
    sub     x11, x20, #1
    cmp     x10, x11
    csel    x10, x10, x11, ls
    sub     x20, x20, x10
.Lpr_loop:
    cbz     x10, .Lpr_ret
    strb    w9, [x19], #1
    sub     x10, x10, #1
    b       .Lpr_loop
.Lpr_ret:
    ret
    .size L_putrep, .-L_putrep

/*==============================================================================
 * internal: L_emit_num(x9 = prefix, x12 = prefix len, x10 = digits, x11 = len)
 *------------------------------------------------------------------------------
 * Emit prefix+digits with the width (x26) and flags (x25). Zero padding lands
 * after the prefix. x30 is stashed while the leaf helpers are called.
 *============================================================================*/
    .type  L_emit_num, %function
    .p2align 2
L_emit_num:
    str     x30, [sp, #LR_SAVE]
    str     x9,  [sp, #PRE_PTR]
    str     x12, [sp, #PRE_LEN]
    str     x10, [sp, #DIG_PTR]
    str     x11, [sp, #DIG_LEN]
    add     x13, x11, x12               /* content length                   */
    mov     x14, #0
    cmp     x26, x13
    b.ls    .Len_nopad
    sub     x14, x26, x13
.Len_nopad:
    str     x14, [sp, #PAD]
    tst     x25, #1
    b.ne    .Len_left
    tst     x25, #2
    b.ne    .Len_zero
    /* right justified, spaces */
    mov     w9, #32
    mov     x10, x14
    bl      L_putrep
    ldr     x9,  [sp, #PRE_PTR]
    ldr     x10, [sp, #PRE_LEN]
    bl      L_putn
    ldr     x9,  [sp, #DIG_PTR]
    ldr     x10, [sp, #DIG_LEN]
    bl      L_putn
    ldr     x30, [sp, #LR_SAVE]
    ret
.Len_zero:
    ldr     x9,  [sp, #PRE_PTR]
    ldr     x10, [sp, #PRE_LEN]
    bl      L_putn
    mov     w9, #48
    ldr     x10, [sp, #PAD]
    bl      L_putrep
    ldr     x9,  [sp, #DIG_PTR]
    ldr     x10, [sp, #DIG_LEN]
    bl      L_putn
    ldr     x30, [sp, #LR_SAVE]
    ret
.Len_left:
    ldr     x9,  [sp, #PRE_PTR]
    ldr     x10, [sp, #PRE_LEN]
    bl      L_putn
    ldr     x9,  [sp, #DIG_PTR]
    ldr     x10, [sp, #DIG_LEN]
    bl      L_putn
    mov     w9, #32
    ldr     x10, [sp, #PAD]
    bl      L_putrep
    ldr     x30, [sp, #LR_SAVE]
    ret
    .size L_emit_num, .-L_emit_num

/*==============================================================================
 * internal: L_emit_str(x9 = ptr, x10 = len)
 *------------------------------------------------------------------------------
 * Emit a known-length string with the width (spaces only; '0' is ignored for
 * strings). x30 is stashed while the leaf helpers are called.
 *============================================================================*/
    .type  L_emit_str, %function
    .p2align 2
L_emit_str:
    str     x30, [sp, #LR_SAVE]
    str     x9,  [sp, #DIG_PTR]
    str     x10, [sp, #DIG_LEN]
    mov     x14, #0
    cmp     x26, x10
    b.ls    .Les_nopad
    sub     x14, x26, x10
.Les_nopad:
    str     x14, [sp, #PAD]
    tst     x25, #1
    b.ne    .Les_left
    mov     w9, #32
    mov     x10, x14
    bl      L_putrep
    ldr     x9,  [sp, #DIG_PTR]
    ldr     x10, [sp, #DIG_LEN]
    bl      L_putn
    ldr     x30, [sp, #LR_SAVE]
    ret
.Les_left:
    ldr     x9,  [sp, #DIG_PTR]
    ldr     x10, [sp, #DIG_LEN]
    bl      L_putn
    mov     w9, #32
    ldr     x10, [sp, #PAD]
    bl      L_putrep
    ldr     x30, [sp, #LR_SAVE]
    ret
    .size L_emit_str, .-L_emit_str

/*==============================================================================
 * int asm_snprintf(char *dst, size_t size, const char *fmt, ...)
 *============================================================================*/
    .globl asm_snprintf
    .type  asm_snprintf, %function
    .p2align 2
asm_snprintf:
    /* ---- prologue: frame, callee-saved registers, locals ---- */
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!
    stp     x21, x22, [sp, #-16]!
    stp     x23, x24, [sp, #-16]!
    stp     x25, x26, [sp, #-16]!
    stp     x27, x28, [sp, #-16]!
    sub     sp, sp, #192
    /* ---- capture the vararg register half ---- */
    stp     x3, x4, [sp, #ARG0]
    stp     x5, x6, [sp, #ARG2]
    str     x7, [sp, #ARG4]
    mov     x28, sp                     /* save-area base                   */
    mov     x23, #0                     /* GPR varargs consumed             */
    add     x24, x29, #16               /* first stacked vararg             */
    /* ---- sink state ---- */
    mov     x19, x0                     /* cursor                           */
    mov     x20, x1                     /* bytes left (incl. NUL)           */
    mov     x21, #0                     /* would-be length                  */
    mov     x22, x2                     /* format cursor                    */
.Lloop:
    ldrb    w9, [x22], #1
    cbz     w9, .Ldone
    cmp     w9, #37                     /* '%'                              */
    b.eq    .Lconv
    bl      L_putc
    b       .Lloop

    /* ---- a conversion: flags, width, length modifier, specifier ---- */
.Lconv:
    mov     x25, #0
    mov     x26, #0
    mov     x27, #0
.Lflags:
    ldrb    w9, [x22]
    cmp     w9, #45                     /* '-'                              */
    b.eq    .Lflag_left
    cmp     w9, #48                     /* '0'                              */
    b.eq    .Lflag_zero
    b       .Lwidth
.Lflag_left:
    orr     x25, x25, #1
    add     x22, x22, #1
    b       .Lflags
.Lflag_zero:
    orr     x25, x25, #2
    add     x22, x22, #1
    b       .Lflags
.Lwidth:
    ldrb    w9, [x22]
    sub     w10, w9, #48
    cmp     w10, #9
    b.hi    .Llength
    mov     x11, #10
    mul     x26, x26, x11
    add     x26, x26, x10
    mov     x11, #0x7fffffff
    cmp     x26, x11
    csel    x26, x26, x11, ls
    add     x22, x22, #1
    b       .Lwidth
.Llength:
    ldrb    w9, [x22]
    cmp     w9, #108                    /* 'l'                              */
    b.ne    .Lspec
    mov     x27, #1
    add     x22, x22, #1
    ldrb    w9, [x22]
    cmp     w9, #108
    b.ne    .Lspec
    add     x22, x22, #1
.Lspec:
    ldrb    w9, [x22], #1
    cmp     w9, #100                    /* 'd'                              */
    b.eq    .Lint_signed
    cmp     w9, #105                    /* 'i'                              */
    b.eq    .Lint_signed
    cmp     w9, #117                    /* 'u'                              */
    b.eq    .Luint
    cmp     w9, #120                    /* 'x'                              */
    b.eq    .Lhex_lower
    cmp     w9, #88                     /* 'X'                              */
    b.eq    .Lhex_upper
    cmp     w9, #111                    /* 'o'                              */
    b.eq    .Loct
    cmp     w9, #99                     /* 'c'                              */
    b.eq    .Lchar
    cmp     w9, #115                    /* 's'                              */
    b.eq    .Lstring
    cmp     w9, #112                    /* 'p'                              */
    b.eq    .Lpointer
    cmp     w9, #37                     /* '%'                              */
    b.eq    .Lpercent
    /* unsupported: copy '%' and the specifier literally, no argument */
    mov     w9, #37
    bl      L_putc
    ldrb    w9, [x22, #-1]
    bl      L_putc
    b       .Lloop
.Lpercent:
    mov     w9, #37
    bl      L_putc
    b       .Lloop

    /* ---- signed decimal ---- */
.Lint_signed:
    bl      L_nextarg
    cbz     x27, .Lis32
    b       .Lis64
.Lis32:
    sxtw    x0, w0
.Lis64:
    mov     x9, #0
    cmp     x0, #0
    b.ge    .Lis_pos
    neg     x0, x0
    mov     x9, #45
.Lis_pos:
    str     x9, [sp, #SIGN]
    mov     x1, #10
    mov     x2, #0
    add     x3, sp, #SCRATCH_END
    bl      L_gen_digits
    add     x9, sp, #SIGN
    mov     x12, #1
    ldr     x13, [sp, #SIGN]
    cbnz    x13, .Lis_pre
    mov     x12, #0
.Lis_pre:
    bl      L_emit_num
    b       .Lloop

    /* ---- unsigned decimal / hex / octal ---- */
.Luint:
    bl      L_nextarg
    cbz     x27, .Lu32
    b       .Lu64
.Lu32:
    mov     w0, w0
.Lu64:
    mov     x1, #10
    mov     x2, #0
    add     x3, sp, #SCRATCH_END
    bl      L_gen_digits
    mov     x9, #0
    mov     x12, #0
    bl      L_emit_num
    b       .Lloop
.Lhex_lower:
    mov     x2, #0
    b       .Lhex
.Lhex_upper:
    mov     x2, #1
.Lhex:
    bl      L_nextarg
    cbz     x27, .Lh32
    b       .Lh64
.Lh32:
    mov     w0, w0
.Lh64:
    mov     x1, #16
    add     x3, sp, #SCRATCH_END
    bl      L_gen_digits
    mov     x9, #0
    mov     x12, #0
    bl      L_emit_num
    b       .Lloop
.Loct:
    bl      L_nextarg
    cbz     x27, .Lo32
    b       .Lo64
.Lo32:
    mov     w0, w0
.Lo64:
    mov     x1, #8
    mov     x2, #0
    add     x3, sp, #SCRATCH_END
    bl      L_gen_digits
    mov     x9, #0
    mov     x12, #0
    bl      L_emit_num
    b       .Lloop

    /* ---- %c ---- */
.Lchar:
    bl      L_nextarg
    str     x0, [sp, #SIGN]
    add     x9, sp, #SIGN
    mov     x10, #1
    bl      L_emit_str
    b       .Lloop

    /* ---- %s ---- */
.Lstring:
    bl      L_nextarg
    cbnz    x0, .Lstr_ok
    adrp    x9, L_nullstr
    add     x9, x9, :lo12:L_nullstr
    mov     x10, #6
    b       .Lstr_emit
.Lstr_ok:
    str     x0, [sp, #SIGN]             /* asm_strlen clobbers caller-saved */
    bl      asm_strlen
    mov     x10, x0
    ldr     x9, [sp, #SIGN]
.Lstr_emit:
    bl      L_emit_str
    b       .Lloop

    /* ---- %p ---- */
.Lpointer:
    bl      L_nextarg
    cbnz    x0, .Lptr_ok
    adrp    x9, L_nilstr
    add     x9, x9, :lo12:L_nilstr
    mov     x10, #5
    bl      L_emit_str
    b       .Lloop
.Lptr_ok:
    mov     x1, #16
    mov     x2, #0
    add     x3, sp, #SCRATCH_END
    bl      L_gen_digits
    adrp    x9, L_hexprefix
    add     x9, x9, :lo12:L_hexprefix
    mov     x12, #2
    bl      L_emit_num
    b       .Lloop

    /* ---- finish ---- */
.Ldone:
    cbz     x20, .Lno_nul
    strb    wzr, [x19]
.Lno_nul:
    mov     w0, w21
    add     sp, sp, #192
    ldp     x27, x28, [sp], #16
    ldp     x25, x26, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret
    .size asm_snprintf, .-asm_snprintf

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
