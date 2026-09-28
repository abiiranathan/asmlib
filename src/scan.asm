;==============================================================================
; scan.asm - a minimal, safe sscanf
;------------------------------------------------------------------------------
;   int asm_sscanf(const char *src, const char *fmt, ...);
;
; Supports %%, %c, %s, %p, %d, %i, %u, %x, %X and %o with the '*' suppression
; flag, a decimal width and the l/ll length modifiers. %s requires a width and
; writes at most width bytes plus a NUL; nothing ever reads past the source's
; terminating NUL. See include/asmlib.h for the full contract.
;
; Returns the number of successful assignments, or -1 on an input failure
; before the first conversion or a malformed/unsupported format.
;
; Implementation notes
; --------------------
; The scanner walks the format and the input together. Integer fields are
; parsed with a bounded digit loop that saturates to the destination type's
; range, so no overflow is possible; the source pointer only ever moves to a
; byte it has inspected, so a NUL always terminates safely.
;==============================================================================

BITS 64
default rel

%include "common.inc"

; ---- asm_sscanf stack frame (rbp-relative) ----------------------------------
%define S_ARG0   (rbp-72)           ; qword: saved vararg rdx
%define S_ARG1   (rbp-64)           ; qword: saved vararg rcx
%define S_ARG2   (rbp-56)           ; qword: saved vararg r8
%define S_ARG3   (rbp-48)           ; qword: saved vararg r9
%define S_ARGN   (rbp-80)           ; qword: varargs consumed (0..4)
%define S_STK    (rbp-88)           ; qword: next stacked vararg
%define S_WIDTH  (rbp-96)           ; qword: current field width (0 = none)
%define S_FLAGS  (rbp-104)          ; qword: bit0 '*', bit1 l/ll
%define S_SIGNED (rbp-112)          ; qword: nonzero for d/i
%define S_DEST   (rbp-120)          ; qword: current destination pointer
%define S_BASE   (rbp-128)          ; qword: 0 auto, else 8/10/16
%define S_START  (rbp-136)          ; qword: cursor at the start of a number

section .text

;==============================================================================
; internal: L_nextarg -> rax
;------------------------------------------------------------------------------
; Return the next vararg slot. rdx, rcx, r8 and r9 hold the first four, then
; the stacked arguments begin at [rbp+16].
; Clobbers: rax, rdx
;==============================================================================
L_nextarg:
    mov     rax, [S_ARGN]
    cmp     rax, 4
    jae     .stack
    mov     rdx, [S_ARG0 + rax*8]
    inc     rax
    mov     [S_ARGN], rax
    mov     rax, rdx
    ret
.stack:
    mov     rdx, [S_STK]
    mov     rax, [rdx]
    add     rdx, 8
    mov     [S_STK], rdx
    ret

;==============================================================================
; internal: L_skip_ws -> void
;------------------------------------------------------------------------------
; Advance rbx over C white space (space, \t..\r). Stops at NUL.
; Clobbers: rax
;==============================================================================
L_skip_ws:
    movzx   eax, byte [rbx]
    cmp     al, ' '
    je      .adv
    cmp     al, 9
    jb      .ret
    cmp     al, 13
    ja      .ret
.adv:
    inc     rbx
    jmp     L_skip_ws
.ret:
    ret

;==============================================================================
; internal: L_parse_digits -> rax = magnitude, edi = digit count
;------------------------------------------------------------------------------
; In:  rbx = input, r10d = base (8/10/16), r9 = field end (exclusive),
;      r8 = magnitude saturation limit
; Out: rax = value (saturated), edi = number of digits, r11d = 1 if saturated,
;      rbx advanced
; Clobbers: rcx, rdx, rsi
;==============================================================================
L_parse_digits:
    xor     eax, eax
    xor     edi, edi
    xor     r11d, r11d
.next:
    cmp     rbx, r9
    jae     .done
    movzx   ecx, byte [rbx]
    cmp     r10d, 10
    je      .d10
    cmp     r10d, 16
    je      .d16
    ; ---- base 8 ----
    sub     ecx, '0'
    cmp     ecx, 7
    ja      .done
    jmp     .have
.d10:
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .done
    jmp     .have
.d16:
    movzx   ecx, byte [rbx]
    sub     ecx, '0'
    cmp     ecx, 9
    jbe     .have
    movzx   ecx, byte [rbx]
    or      ecx, 0x20
    sub     ecx, 'a'
    cmp     ecx, 5
    ja      .done
    add     ecx, 10
.have:
    mul     r10                         ; rdx:rax = value * base
    test    rdx, rdx
    jnz     .saturate
    add     rax, rcx
    jc      .saturate
    cmp     rax, r8
    ja      .saturate
    jmp     .taken
.saturate:
    mov     rax, r8
    mov     r11d, 1
.taken:
    inc     rbx
    inc     edi
    jmp     .next
.done:
    ret

;==============================================================================
; int asm_sscanf(const char *src, const char *fmt, ...)
;------------------------------------------------------------------------------
; Parameters (System V AMD64 ABI):
;   rdi = src (const char *)  - NUL-terminated input
;   rsi = fmt (const char *)  - format string
;   ...  = destination pointers in rdx, rcx, r8, r9 then on the stack
; Returns:
;   eax = assignments made, or -1 on input failure / format error
;==============================================================================
global asm_sscanf:function
asm_sscanf:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 104
    ; ---- capture the vararg register half ----
    mov     [S_ARG0], rdx
    mov     [S_ARG1], rcx
    mov     [S_ARG2], r8
    mov     [S_ARG3], r9
    mov     qword [S_ARGN], 0
    lea     rax, [rbp+16]
    mov     [S_STK], rax
    ; ---- scanner state ----
    mov     rbx, rdi                    ; input cursor
    mov     r12, rsi                    ; format cursor
    xor     r13d, r13d                  ; assignment count
.loop:
    movzx   eax, byte [r12]
    inc     r12
    test    al, al
    jz      .done
    cmp     al, '%'
    je      .conv
    ; ---- format whitespace matches a run of input whitespace ----
    cmp     al, ' '
    je      .fmt_ws
    cmp     al, 9
    jb      .literal
    cmp     al, 13
    jbe     .fmt_ws
.literal:
    cmp     byte [rbx], al
    jne     .mismatch
    inc     rbx
    jmp     .loop
.fmt_ws:
    call    L_skip_ws
    jmp     .loop

    ; ---- a conversion: '*', width, length, specifier ----
.conv:
    mov     qword [S_FLAGS], 0
    mov     qword [S_WIDTH], 0
    mov     qword [S_SIGNED], 0
    cmp     byte [r12], '*'
    jne     .no_suppress
    or      qword [S_FLAGS], 1
    inc     r12
.no_suppress:
.width:
    movzx   eax, byte [r12]
    sub     eax, '0'
    cmp     eax, 9
    ja      .length
    mov     rcx, [S_WIDTH]
    imul    rcx, rcx, 10
    add     rcx, rax
    mov     [S_WIDTH], rcx
    inc     r12
    jmp     .width
.length:
    cmp     byte [r12], 'l'
    jne     .spec
    or      qword [S_FLAGS], 2
    inc     r12
    cmp     byte [r12], 'l'
    jne     .spec
    inc     r12
.spec:
    movzx   eax, byte [r12]
    inc     r12
    cmp     al, '%'
    je      .percent
    cmp     al, 'c'
    je      .char
    cmp     al, 's'
    je      .string
    cmp     al, 'd'
    je      .signed_dec
    cmp     al, 'i'
    je      .signed_auto
    cmp     al, 'u'
    je      .unsigned_dec
    cmp     al, 'x'
    je      .hex
    cmp     al, 'X'
    je      .hex
    cmp     al, 'o'
    je      .oct
    cmp     al, 'p'
    je      .pointer
    jmp     .fmt_error                  ; unsupported conversion

.percent:
    cmp     byte [rbx], '%'
    jne     .mismatch
    inc     rbx
    jmp     .loop

    ; ---- %c: width bytes (default 1), no whitespace skip, no NUL ----
.char:
    mov     r15, [S_WIDTH]
    test    r15, r15
    jnz     .char_dest
    mov     r15, 1
.char_dest:
    test    qword [S_FLAGS], 1
    jnz     .char_read
    call    L_nextarg
    mov     [S_DEST], rax
.char_read:
    mov     r14, r15
.char_copy:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .input_fail
    test    qword [S_FLAGS], 1
    jnz     .char_skip
    mov     rdi, [S_DEST]
    mov     [rdi], al
    inc     qword [S_DEST]
.char_skip:
    inc     rbx
    dec     r14
    jnz     .char_copy
    test    qword [S_FLAGS], 1
    jnz     .loop
    inc     r13
    jmp     .loop

    ; ---- %s: whitespace-delimited, NUL-terminated; width required unless '*' ----
.string:
    mov     r15, [S_WIDTH]
    test    r15, r15
    jnz     .str_have
    test    qword [S_FLAGS], 1
    jz      .fmt_error                  ; a stored %s needs a width
    mov     r15, -1                     ; suppressed: unbounded is safe
.str_have:
    test    qword [S_FLAGS], 1
    jnz     .str_skip
    call    L_nextarg
    mov     [S_DEST], rax
.str_skip:
    call    L_skip_ws
    xor     r14d, r14d
.str_read:
    test    r15, r15
    jz      .str_done
    movzx   eax, byte [rbx]
    test    al, al
    jz      .str_done
    cmp     al, ' '
    je      .str_done
    cmp     al, 9
    jb      .str_store
    cmp     al, 13
    jbe     .str_done
.str_store:
    test    qword [S_FLAGS], 1
    jnz     .str_skip2
    mov     rdi, [S_DEST]
    mov     [rdi], al
    inc     qword [S_DEST]
.str_skip2:
    inc     rbx
    dec     r15
    inc     r14
    jmp     .str_read
.str_done:
    test    r14, r14
    jz      .str_fail
    test    qword [S_FLAGS], 1
    jnz     .loop
    mov     rdi, [S_DEST]
    mov     byte [rdi], 0
    inc     r13
    jmp     .loop
.str_fail:
    cmp     byte [rbx], 0
    je      .eof
    jmp     .stop

    ; ---- integers ----
.signed_dec:
    mov     qword [S_SIGNED], 1
    mov     qword [S_BASE], 10
    jmp     .number
.signed_auto:
    mov     qword [S_SIGNED], 1
    mov     qword [S_BASE], 0
    jmp     .number
.unsigned_dec:
    mov     qword [S_BASE], 10
    jmp     .number
.hex:
    mov     qword [S_BASE], 16
    jmp     .number
.oct:
    mov     qword [S_BASE], 8
    jmp     .number
.pointer:
    mov     qword [S_BASE], 16
    or      qword [S_FLAGS], 2          ; pointers are 64-bit
    jmp     .number

.number:
    call    L_skip_ws
    mov     [S_START], rbx
    ; field end = cursor + width (0 = unbounded)
    mov     r9, [S_WIDTH]
    test    r9, r9
    jz      .num_nowidth
    add     r9, rbx
    jmp     .num_wlim
.num_nowidth:
    mov     r9, -1
.num_wlim:
    ; optional sign
    xor     r15d, r15d
    cmp     rbx, r9
    jae     .num_sign_done
    movzx   eax, byte [rbx]
    cmp     al, '+'
    je      .num_sign_skip
    cmp     al, '-'
    jne     .num_sign_done
    mov     r15d, 1
.num_sign_skip:
    inc     rbx
.num_sign_done:
    ; base selection / optional prefix
    mov     r10d, [S_BASE]
    test    r10d, r10d
    jnz     .num_base
    ; %i: auto-detect
    movzx   eax, byte [rbx]
    cmp     al, '0'
    jne     .num_auto_dec
    movzx   eax, byte [rbx+1]
    or      al, 0x20
    cmp     al, 'x'
    jne     .num_auto_oct
    mov     r10d, 16
    add     rbx, 2
    jmp     .num_base
.num_auto_oct:
    mov     r10d, 8
    jmp     .num_base
.num_auto_dec:
    mov     r10d, 10
.num_base:
    cmp     r10d, 16
    jne     .num_limit
    ; skip an explicit 0x prefix
    cmp     rbx, r9
    jae     .num_limit
    cmp     byte [rbx], '0'
    jne     .num_limit
    lea     rax, [rbx+1]
    cmp     rax, r9
    jae     .num_limit
    movzx   eax, byte [rbx+1]
    or      al, 0x20
    cmp     al, 'x'
    jne     .num_limit
    add     rbx, 2
.num_limit:
    ; scanf parses into a 64-bit value (with strto* saturation) and then
    ; truncates to the destination; only the sign chooses the 64-bit limit.
    cmp     qword [S_SIGNED], 0
    je      .limu
    test    r15d, r15d
    jnz     .limn
    mov     r8, 0x7fffffffffffffff
    jmp     .lim_done
.limn:
    mov     r8, 0x8000000000000000
    jmp     .lim_done
.limu:
    mov     r8, -1
.lim_done:
    call    L_parse_digits
    test    edi, edi
    jz      .num_fail
    test    r15d, r15d
    jz      .num_positive
    ; strtoull returns the unsigned limit unchanged when it saturated, so an
    ; out-of-range negative %u/%x/%o is not negated.
    test    r11d, r11d
    jz      .num_negate
    cmp     qword [S_SIGNED], 0
    jne     .num_negate
    jmp     .num_positive
.num_negate:
    neg     rax
.num_positive:
    mov     r14, rax                    ; keep the value across L_nextarg
    test    qword [S_FLAGS], 1
    jnz     .num_nodest
    call    L_nextarg
    mov     [S_DEST], rax
.num_nodest:
    test    qword [S_FLAGS], 1
    jnz     .loop
    mov     rdi, [S_DEST]
    test    qword [S_FLAGS], 2
    jnz     .num_store64
    mov     [rdi], r14d
    jmp     .num_count
.num_store64:
    mov     [rdi], r14
.num_count:
    inc     r13
    jmp     .loop
.num_fail:
    cmp     rbx, [S_START]
    jne     .stop                       ; consumed sign/prefix -> matching failure
    cmp     byte [rbx], 0
    je      .eof
    jmp     .stop

    ; ---- terminators ----
.mismatch:
    cmp     byte [rbx], 0
    je      .eof
    jmp     .stop
.input_fail:
.eof:
    test    r13, r13
    jz      .return_eof
.stop:
    mov     eax, r13d
    jmp     .epilogue
.return_eof:
    mov     eax, -1
    jmp     .epilogue
.fmt_error:
    mov     eax, -1
    jmp     .epilogue
.done:
    mov     eax, r13d
.epilogue:
    add     rsp, 104
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

GNU_STACK_NOTE
