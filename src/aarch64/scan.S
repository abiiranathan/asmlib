/*==============================================================================
 * scan.S - a minimal, safe sscanf (AArch64)
 *------------------------------------------------------------------------------
 * SPDX-License-Identifier: MIT
 *
 * AArch64 port of src/scan.asm. Supports %%, %c, %s, %p, %d, %i, %u, %x, %X
 * and %o with the '*' suppression flag, a decimal width and the l/ll length
 * modifiers. %s requires a width unless suppressed and writes at most width
 * bytes plus a NUL; nothing ever reads past the source's NUL. See
 * include/asmlib.h for the full contract.
 *
 * AAPCS64: x0 = src, x1 = fmt, the varargs are x2..x7 then the stack (which
 * starts at x29+16 once the frame pointer is set). x19..x28 hold the scanner
 * state and are saved/restored here.
 *============================================================================*/

#include "common_aarch64.inc"

#define ARG0    0
#define ARG1    8
#define ARG2    16
#define ARG3    24
#define ARG4    32
#define ARG5    40
#define S_WIDTH 48
#define S_FLAGS 56
#define S_SGN   64
#define S_BASE  72
#define S_DEST  80
#define S_START 88

    .text

/*------------------------------------------------------------------------------
 * internal: L_nextarg -> x0
 *------------------------------------------------------------------------------
 * The first six varargs are x2..x7 (saved at sp+ARG0); the rest are stacked
 * from x24. Preserves x19..x28.
 *----------------------------------------------------------------------------*/
    .type  L_nextarg, %function
    .p2align 2
L_nextarg:
    cmp     x23, #6
    b.hs    .Lna_stack
    ldr     x0, [sp, x23, lsl #3]
    add     x23, x23, #1
    ret
.Lna_stack:
    ldr     x0, [x24], #8
    ret
    .size L_nextarg, .-L_nextarg

/*------------------------------------------------------------------------------
 * internal: L_skip_ws - advance x19 over C white space
 *----------------------------------------------------------------------------*/
    .type  L_skip_ws, %function
    .p2align 2
L_skip_ws:
    ldrb    w9, [x19]
    cmp     w9, #32
    b.eq    .Lws_adv
    sub     w10, w9, #9
    cmp     w10, #4
    b.hi    .Lws_ret
.Lws_adv:
    add     x19, x19, #1
    b       L_skip_ws
.Lws_ret:
    ret
    .size L_skip_ws, .-L_skip_ws

/*------------------------------------------------------------------------------
 * internal: L_parse_digits
 *------------------------------------------------------------------------------
 * In:  x19 = input, x9 = base (8/10/16), x12 = field end, x13 = saturation cap
 * Out: x0 = magnitude (saturated), x10 = digit count, x11 = 1 if saturated,
 *      x19 advanced
 * Clobbers: x0..x3, x9..x13
 *----------------------------------------------------------------------------*/
    .type  L_parse_digits, %function
    .p2align 2
L_parse_digits:
    mov     x0, #0
    mov     x10, #0
    mov     x11, #0
.Lpd_next:
    cmp     x19, x12
    b.hs    .Lpd_done
    ldrb    w1, [x19]
    cmp     x9, #10
    b.eq    .Lpd_d10
    cmp     x9, #16
    b.eq    .Lpd_d16
    sub     w1, w1, #48                     /* base 8 */
    cmp     w1, #7
    b.hi    .Lpd_done
    b       .Lpd_have
.Lpd_d10:
    sub     w1, w1, #48
    cmp     w1, #9
    b.hi    .Lpd_done
    b       .Lpd_have
.Lpd_d16:
    ldrb    w2, [x19]
    sub     w1, w2, #48
    cmp     w1, #9
    b.ls    .Lpd_have
    orr     w2, w2, #0x20
    sub     w1, w2, #97
    cmp     w1, #5
    b.hi    .Lpd_done
    add     w1, w1, #10
.Lpd_have:
    mul     x2, x0, x9
    umulh   x3, x0, x9
    cbnz    x3, .Lpd_sat
    adds    x2, x2, x1
    b.cs    .Lpd_sat
    cmp     x2, x13
    b.hi    .Lpd_sat
    mov     x0, x2
    b       .Lpd_taken
.Lpd_sat:
    mov     x0, x13
    mov     x11, #1
.Lpd_taken:
    add     x19, x19, #1
    add     x10, x10, #1
    b       .Lpd_next
.Lpd_done:
    ret
    .size L_parse_digits, .-L_parse_digits

/*==============================================================================
 * int asm_sscanf(const char *src, const char *fmt, ...)
 *============================================================================*/
    .globl asm_sscanf
    .type  asm_sscanf, %function
    .p2align 2
asm_sscanf:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!
    stp     x21, x22, [sp, #-16]!
    stp     x23, x24, [sp, #-16]!
    stp     x25, x26, [sp, #-16]!
    stp     x27, x28, [sp, #-16]!
    sub     sp, sp, #96
    stp     x2, x3, [sp, #ARG0]
    stp     x4, x5, [sp, #ARG2]
    stp     x6, x7, [sp, #ARG4]
    mov     x23, #0
    add     x24, x29, #16
    mov     x19, x0                         /* input cursor             */
    mov     x20, x1                         /* format cursor            */
    mov     x21, #0                         /* assignment count         */
.Lloop:
    ldrb    w9, [x20], #1
    cbz     w9, .Ldone
    cmp     w9, #37                         /* '%'                      */
    b.eq    .Lconv
    cmp     w9, #32
    b.eq    .Lfmt_ws
    sub     w10, w9, #9
    cmp     w10, #4
    b.ls    .Lfmt_ws
    ldrb    w11, [x19]
    cmp     w11, w9
    b.ne    .Lmismatch
    add     x19, x19, #1
    b       .Lloop
.Lfmt_ws:
    bl      L_skip_ws
    b       .Lloop

.Lconv:
    mov     x26, #0                         /* flags                    */
    mov     x25, #0                         /* width                    */
    mov     x27, #0                         /* signed                   */
    ldrb    w9, [x20]
    cmp     w9, #42                         /* '*'                      */
    b.ne    .Lno_suppress
    orr     x26, x26, #1
    add     x20, x20, #1
.Lno_suppress:
.Lwidth:
    ldrb    w9, [x20]
    sub     w10, w9, #48
    cmp     w10, #9
    b.hi    .Llength
    mov     x11, #10
    mul     x25, x25, x11
    add     x25, x25, x10
    add     x20, x20, #1
    b       .Lwidth
.Llength:
    ldrb    w9, [x20]
    cmp     w9, #108                        /* 'l'                      */
    b.ne    .Lspec
    orr     x26, x26, #2
    add     x20, x20, #1
    ldrb    w9, [x20]
    cmp     w9, #108
    b.ne    .Lspec
    add     x20, x20, #1
.Lspec:
    ldrb    w9, [x20], #1
    cmp     w9, #37
    b.eq    .Lpercent
    cmp     w9, #99                         /* 'c'                      */
    b.eq    .Lchar
    cmp     w9, #115                        /* 's'                      */
    b.eq    .Lstring
    cmp     w9, #100                        /* 'd'                      */
    b.eq    .Lsigned_dec
    cmp     w9, #105                        /* 'i'                      */
    b.eq    .Lsigned_auto
    cmp     w9, #117                        /* 'u'                      */
    b.eq    .Lunsigned_dec
    cmp     w9, #120                        /* 'x'                      */
    b.eq    .Lhex
    cmp     w9, #88                         /* 'X'                      */
    b.eq    .Lhex
    cmp     w9, #111                        /* 'o'                      */
    b.eq    .Loct
    cmp     w9, #112                        /* 'p'                      */
    b.eq    .Lpointer
    b       .Lfmt_error

.Lpercent:
    ldrb    w9, [x19]
    cmp     w9, #37
    b.ne    .Lmismatch
    add     x19, x19, #1
    b       .Lloop

    /* ---- %c ---- */
.Lchar:
    cbz     x25, .Lchar_one
    b       .Lchar_dest
.Lchar_one:
    mov     x25, #1
.Lchar_dest:
    tst     x26, #1
    b.ne    .Lchar_read
    bl      L_nextarg
    str     x0, [sp, #S_DEST]
.Lchar_read:
    mov     x22, x25
.Lchar_copy:
    ldrb    w9, [x19]
    cbz     w9, .Linput_fail
    tst     x26, #1
    b.ne    .Lchar_skip
    ldr     x10, [sp, #S_DEST]
    strb    w9, [x10]
    add     x10, x10, #1
    str     x10, [sp, #S_DEST]
.Lchar_skip:
    add     x19, x19, #1
    subs    x22, x22, #1
    b.ne    .Lchar_copy
    tst     x26, #1
    b.ne    .Lloop
    add     x21, x21, #1
    b       .Lloop

    /* ---- %s ---- */
.Lstring:
    cbnz    x25, .Lstr_have
    tst     x26, #1
    b.eq    .Lfmt_error
    mov     x25, #-1
.Lstr_have:
    tst     x26, #1
    b.ne    .Lstr_skip
    bl      L_nextarg
    str     x0, [sp, #S_DEST]
.Lstr_skip:
    bl      L_skip_ws
    mov     x22, #0
.Lstr_read:
    cbz     x25, .Lstr_done
    ldrb    w9, [x19]
    cbz     w9, .Lstr_done
    cmp     w9, #32
    b.eq    .Lstr_done
    sub     w10, w9, #9
    cmp     w10, #4
    b.ls    .Lstr_done
    tst     x26, #1
    b.ne    .Lstr_skip2
    ldr     x10, [sp, #S_DEST]
    strb    w9, [x10]
    add     x10, x10, #1
    str     x10, [sp, #S_DEST]
.Lstr_skip2:
    add     x19, x19, #1
    sub     x25, x25, #1
    add     x22, x22, #1
    b       .Lstr_read
.Lstr_done:
    cbz     x22, .Lstr_fail
    tst     x26, #1
    b.ne    .Lloop
    ldr     x10, [sp, #S_DEST]
    strb    wzr, [x10]
    add     x21, x21, #1
    b       .Lloop
.Lstr_fail:
    ldrb    w9, [x19]
    cbz     w9, .Leof
    b       .Lstop

    /* ---- integers ---- */
.Lsigned_dec:
    mov     x27, #1
    mov     x28, #10
    b       .Lnumber
.Lsigned_auto:
    mov     x27, #1
    mov     x28, #0
    b       .Lnumber
.Lunsigned_dec:
    mov     x28, #10
    b       .Lnumber
.Lhex:
    mov     x28, #16
    b       .Lnumber
.Loct:
    mov     x28, #8
    b       .Lnumber
.Lpointer:
    mov     x28, #16
    orr     x26, x26, #2
    b       .Lnumber
.Lnumber:
    bl      L_skip_ws
    mov     x12, x19
    str     x12, [sp, #S_START]
    cbz     x25, .Lnum_nowidth
    add     x12, x12, x25
    b       .Lnum_wlim
.Lnum_nowidth:
    mov     x12, #-1
.Lnum_wlim:
    mov     x22, #0                         /* sign                     */
    cmp     x19, x12
    b.hs    .Lnum_sign_done
    ldrb    w9, [x19]
    cmp     w9, #43                         /* '+'                      */
    b.eq    .Lnum_sign_skip
    cmp     w9, #45                         /* '-'                      */
    b.ne    .Lnum_sign_done
    mov     x22, #1
.Lnum_sign_skip:
    add     x19, x19, #1
.Lnum_sign_done:
    mov     x9, x28
    cbnz    x9, .Lnum_base
    /* %i auto-detect */
    ldrb    w9, [x19]
    cmp     w9, #48                         /* '0'                      */
    b.ne    .Lnum_auto_dec
    ldrb    w9, [x19, #1]
    orr     w9, w9, #0x20
    cmp     w9, #120                        /* 'x'                      */
    b.ne    .Lnum_auto_oct
    mov     x9, #16
    add     x19, x19, #2
    b       .Lnum_base
.Lnum_auto_oct:
    mov     x9, #8
    b       .Lnum_base
.Lnum_auto_dec:
    mov     x9, #10
.Lnum_base:
    cmp     x9, #16
    b.ne    .Lnum_limit
    cmp     x19, x12
    b.hs    .Lnum_limit
    ldrb    w10, [x19]
    cmp     w10, #48
    b.ne    .Lnum_limit
    add     x11, x19, #1
    cmp     x11, x12
    b.hs    .Lnum_limit
    ldrb    w10, [x19, #1]
    orr     w10, w10, #0x20
    cmp     w10, #120
    b.ne    .Lnum_limit
    add     x19, x19, #2
.Lnum_limit:
    cbz     x27, .Llimu
    cbnz    x22, .Limn
    ldr     x13, =0x7fffffffffffffff
    b       .Llim_done
.Limn:
    ldr     x13, =0x8000000000000000
    b       .Llim_done
.Llimu:
    mov     x13, #-1
.Llim_done:
    bl      L_parse_digits                  /* x0 mag, x10 count, x11 sat */
    cbz     x10, .Lnum_fail
    cbnz    x22, .Lnum_negate_check
    b       .Lnum_positive
.Lnum_negate_check:
    cbz     x11, .Lnum_negate
    cbz     x27, .Lnum_positive             /* unsigned + saturated: verbatim */
.Lnum_negate:
    neg     x0, x0
.Lnum_positive:
    mov     x22, x0
    tst     x26, #1
    b.ne    .Lloop
    bl      L_nextarg
    mov     x9, x0
    tst     x26, #2
    b.ne    .Lnum_store64
    str     w22, [x9]
    b       .Lnum_count
.Lnum_store64:
    str     x22, [x9]
.Lnum_count:
    add     x21, x21, #1
    b       .Lloop
.Lnum_fail:
    ldr     x10, [sp, #S_START]
    cmp     x19, x10
    b.ne    .Lstop
    ldrb    w9, [x19]
    cbz     w9, .Leof
    b       .Lstop

.Lmismatch:
    ldrb    w9, [x19]
    cbz     w9, .Leof
    b       .Lstop
.Linput_fail:
.Leof:
    cbz     x21, .Lreturn_eof
.Lstop:
    mov     w0, w21
    b       .Lepilogue
.Lreturn_eof:
    mov     w0, #-1
    b       .Lepilogue
.Lfmt_error:
    mov     w0, #-1
    b       .Lepilogue
.Ldone:
    mov     w0, w21
.Lepilogue:
    add     sp, sp, #96
    ldp     x27, x28, [sp], #16
    ldp     x25, x26, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret
    .size asm_sscanf, .-asm_sscanf

GNU_STACK_NOTE
