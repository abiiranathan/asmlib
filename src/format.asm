;==============================================================================
; format.asm - fast integer-to-string conversion
;------------------------------------------------------------------------------
; Bounded integer formatters:
;
;   size_t asm_u64toa      (uint64_t v, char *buf, size_t cap);
;   size_t asm_i64toa      (int64_t  v, char *buf, size_t cap);
;   size_t asm_u64toa_base (uint64_t v, char *buf, size_t cap, unsigned base);
;   size_t asm_u64tohex    (uint64_t v, char *buf, size_t cap, int uppercase);
;
; The full formatted-output engine (asm_snprintf and the rest of the printf
; family, including floating point) is the portable C implementation in
; src/libc/printf.c, which is linked into every backend so the behaviour is
; identical everywhere.
;
; The number formatters never write more than `cap` bytes (including the NUL)
; and return the length the full number needs, so callers can detect
; truncation.
;
; Implementation notes
; --------------------
; Digits are generated into a small stack scratch buffer from the end
; backwards, then copied out most-significant first.
;==============================================================================

BITS 64
default rel

%include "common.inc"

section .text

;==============================================================================
; internal: L_gen_digits
;------------------------------------------------------------------------------
; Generate the digits of rax in base r9d, writing backwards from r10, and
; return the start pointer and length. The value may be zero (one '0' is
; produced).
;
; In:  rax = unsigned value
;      r9d = base (2..36)
;      r8d = nonzero for uppercase letters
;      r10 = one past the end of the scratch buffer
; Out: r11 = pointer to the most significant digit
;      r15 = digit count
; Clobbers: rax, rcx, rdx, rsi
;==============================================================================
L_gen_digits:
    cmp     r9d, 10                     ; hot bases avoid the divider
    je      .dec
    cmp     r9d, 16
    je      .hex
    cmp     r9d, 8
    je      .oct
    jmp     .generic
    ; ---- decimal: fixed-chunk forward writer (no loop, no divide) ----
.dec:
    lea     r15, [r10-24]               ; scratch start (20 digits max)
    mov     rdi, r15
    call    L_dec_forward               ; writes digits; rdi = end
    mov     r11, r15
    mov     r15, rdi
    sub     r15, r11                    ; digit count
    ret
    ; ---- hexadecimal: four bits per digit ----
.hex:
    mov     rsi, r10
    xor     r15d, r15d
    lea     r11, [rel L_hexdig_lc]
    test    r8d, r8d
    jz      .hex_go
    lea     r11, [rel L_hexdig_uc]
.hex_go:
    test    rax, rax
    jnz     .loop_hex
    dec     rsi
    mov     byte [rsi], '0'
    inc     r15
    mov     r11, rsi
    ret
.loop_hex:
    mov     ecx, eax
    and     ecx, 15
    movzx   edx, byte [r11+rcx]
    dec     rsi
    mov     [rsi], dl
    inc     r15
    shr     rax, 4
    jnz     .loop_hex
    mov     r11, rsi
    ret
    ; ---- octal: three bits per digit ----
.oct:
    mov     rsi, r10
    xor     r15d, r15d
    lea     r11, [rel L_digits_lc]
.oct_go:
    test    rax, rax
    jnz     .loop_oct
    dec     rsi
    mov     byte [rsi], '0'
    inc     r15
    mov     r11, rsi
    ret
.loop_oct:
    mov     ecx, eax
    and     ecx, 7
    movzx   edx, byte [r11+rcx]
    dec     rsi
    mov     [rsi], dl
    inc     r15
    shr     rax, 3
    jnz     .loop_oct
    mov     r11, rsi
    ret
    ; ---- general base: hardware divide ----
.generic:
    mov     rsi, r10
    xor     r15d, r15d
.loop:
    xor     edx, edx                    ; clear the high dividend half
    div     r9                          ; rax = quotient, rdx = remainder
    mov     rcx, rdx                    ; rcx = digit value
    cmp     rcx, 9
    jbe     .numeric
    add     rcx, 'a'-10                 ; 10..35 -> a..z
    test    r8d, r8d
    jz      .store
    sub     rcx, 32                     ; fold to A..Z when asked
    jmp     .store
.numeric:
    add     rcx, '0'
.store:
    dec     rsi
    mov     [rsi], cl
    inc     r15
    test    rax, rax
    jnz     .loop
    mov     r11, rsi                    ; r11 = first digit
    ret

;==============================================================================
; internal: L_dec_forward(rax = value, rdi = dst) -> rdi = end
;------------------------------------------------------------------------------
; Write the decimal digits of rax forward with no loop: the magnitude selects
; a fixed-chunk path built from a 200-byte two-digit table and reciprocal
; multiplies. Callers must guarantee at least 20 writable bytes at dst; the
; write is exact (no padding) and leaves rdi one past the last digit.
;
; Clobbers rax, rcx, rdx, rsi, rdi, r8, r9, r10. All digit subroutines are leaf
; except the recursive L_u32_to_str; saved values live on the stack, so r10
; (the digit-pair table) and nothing else need survive across them.
;==============================================================================
L_dec_forward:
    lea     r10, [rel L_dec_pairs]
    mov     rsi, rax
    mov     r8, 0xFFFFFFFF
    cmp     rsi, r8
    ja      .big
    mov     eax, esi                    ; 0..2^32-1
    call    L_u32_to_str
    ret
.big:
    mov     r8, 10000000000000000
    cmp     rsi, r8
    jae     .huge
    ; ---- 9..16 digits: hi64 = v/1e8, lo32 = v%1e8 ----
    mov     rax, rsi
    mov     r9, 0xabcc77118461cefd      ; magic for /1e8 (shift 26)
    mul     r9
    shr     rdx, 26                     ; rdx = v / 1e8
    mov     rcx, 100000000
    imul    rcx, rdx
    sub     rsi, rcx                    ; lo32
    mov     eax, edx                    ; hi64 (< 1e8)
    push    rsi
    call    L_u32_to_str
    pop     rcx
    call    L_put8
    ret
.huge:
    ; ---- 17..20 digits: split off v/1e16, then 1e8 again ----
    mov     rax, rsi
    mov     r9, 0x39a5652fb1137857      ; magic for /1e16 (shift 51)
    mul     r9
    shr     rdx, 51                     ; rdx = hi_hi32 (< 1845)
    mov     r8, rdx
    mov     rcx, 10000000000000000
    imul    rcx, r8
    sub     rsi, rcx                    ; rem16
    mov     eax, r8d
    push    rsi
    call    L_u32_to_str
    pop     rsi
    mov     rax, rsi
    mov     r9, 0xabcc77118461cefd
    mul     r9
    shr     rdx, 26                     ; hi_lo32
    mov     rcx, 100000000
    imul    rcx, rdx
    sub     rsi, rcx                    ; lo32
    push    rsi
    mov     ecx, edx
    call    L_put8
    pop     rcx
    call    L_put8
    ret

;==============================================================================
; internal: L_u32_to_str(eax = value) -> writes at rdi
;------------------------------------------------------------------------------
; 0..2^32-1, most significant chunk first, using the magnitude to pick a fixed
; chunk size. Recurses once for the 5..8 digit case.
;==============================================================================
L_u32_to_str:
    cmp     eax, 100
    jb      .lt100
    cmp     eax, 10000
    jb      .lt1e4
    cmp     eax, 100000000
    jb      .lt1e8
    ; 9..10 digits: hi = v/1e8, lo = v%1e8
    mov     ecx, eax
    mov     edx, 1441151881             ; /1e8 (32-bit, shift 57)
    imul    rax, rdx
    shr     rax, 57
    imul    edx, eax, 100000000
    sub     ecx, edx
    push    rcx
    mov     ecx, eax
    call    L_write_tail2
    pop     rcx
    call    L_put8
    ret
.lt1e8:
    ; 5..8 digits: hi = v/10000, lo = v%10000
    mov     ecx, eax
    mov     edx, 3518437209             ; /10000 (32-bit, shift 45)
    imul    rax, rdx
    shr     rax, 45
    imul    edx, eax, 10000
    sub     ecx, edx
    push    rcx
    mov     ecx, eax
    call    L_u32_to_str
    pop     rcx
    call    L_put4
    ret
.lt1e4:
    ; 3..4 digits: q = v/100, r = v%100
    mov     ecx, eax
    imul    rax, rax, 1374389535        ; /100 (32-bit, shift 37)
    shr     rax, 37
    imul    edx, eax, 100
    sub     ecx, edx
    push    rcx
    mov     ecx, eax
    call    L_write_tail2
    pop     rcx
    call    L_put2
    ret
.lt100:
    mov     ecx, eax
    jmp     L_write_tail2

;==============================================================================
; internal: L_write_tail2(ecx = 0..99) -> writes one or two digits
;==============================================================================
L_write_tail2:
    cmp     ecx, 10
    jae     .two
    add     ecx, '0'
    mov     [rdi], cl
    inc     rdi
    ret
.two:
    jmp     L_put2

;==============================================================================
; internal: L_put2(ecx = 0..99) -> two digits at rdi
;==============================================================================
L_put2:
    movzx   edx, word [r10+rcx*2]
    mov     [rdi], dx
    add     rdi, 2
    ret

;==============================================================================
; internal: L_put4(ecx = 0..9999) -> four digits at rdi
;==============================================================================
L_put4:
    mov     eax, ecx
    imul    rax, rax, 1374389535        ; q = v / 100
    shr     rax, 37
    imul    edx, eax, 100
    sub     ecx, edx                    ; r = v % 100
    movzx   edx, word [r10+rax*2]       ; high pair
    mov     [rdi], dx
    movzx   edx, word [r10+rcx*2]       ; low pair
    mov     [rdi+2], dx
    add     rdi, 4
    ret

;==============================================================================
; internal: L_put8(ecx = 0..99999999) -> eight digits at rdi
;==============================================================================
L_put8:
    mov     eax, ecx
    mov     edx, 3518437209             ; hi = v / 10000
    imul    rax, rdx
    shr     rax, 45
    imul    edx, eax, 10000
    sub     ecx, edx                    ; lo = v % 10000
    push    rcx
    mov     ecx, eax
    call    L_put4
    pop     rcx
    call    L_put4
    ret

;==============================================================================
; internal: L_utoa_base_case
;------------------------------------------------------------------------------
; Shared core of the unsigned formatters.
;
; In:  rdi = value, rsi = buf, rdx = cap, r10 = base, r11d = uppercase
; Out: rax = full length (excluding NUL)
;==============================================================================
L_utoa_base_case:
    push    r12                         ; preserve callee-saved
    push    r13
    push    r15
    sub     rsp, 72                     ; 64-byte digit scratch + slack
    mov     r12, rsi                    ; r12 = buf
    mov     r13, rdx                    ; r13 = cap
    cmp     r10, 2
    jb      .bad
    cmp     r10, 36
    ja      .bad
    mov     r9, r10                     ; base for L_gen_digits
    mov     r8, r11                     ; uppercase flag
    lea     r10, [rsp+72]               ; scratch end
    mov     rax, rdi                    ; value
    call    L_gen_digits                ; r11 = digits, r15 = count
    test    r13, r13
    jz      .out
    mov     rcx, r13
    dec     rcx                         ; writable bytes
    cmp     rcx, r15
    jbe     .have
    mov     rcx, r15
.have:
    mov     rsi, r11
    mov     rdi, r12
    rep     movsb
    mov     byte [rdi], 0
.out:
    mov     rax, r15
    add     rsp, 72
    pop     r15
    pop     r13
    pop     r12
    ret
.bad:
    test    r13, r13
    jz      .bad_ret
    mov     byte [r12], 0
.bad_ret:
    xor     eax, eax
    add     rsp, 72
    pop     r15
    pop     r13
    pop     r12
    ret

;==============================================================================
; size_t asm_u64toa(uint64_t value, char *buf, size_t cap)
;------------------------------------------------------------------------------
; When cap is large enough for any 64-bit decimal the digits are written
; straight into buf (no scratch and no copy); otherwise the shared bounded
; path formats into a small scratch and copies the leading bytes.
;==============================================================================
global asm_u64toa:function
asm_u64toa:
    cmp     rdx, 21                     ; 20 digits + NUL fits?
    jb      .small
    push    rbx
    mov     rbx, rsi                    ; remember buf
    mov     rax, rdi
    mov     rdi, rsi
    call    L_dec_forward               ; rdi = end
    mov     byte [rdi], 0
    mov     rax, rdi
    sub     rax, rbx
    pop     rbx
    ret
.small:
    mov     r10d, 10
    xor     r11d, r11d
    jmp     L_utoa_base_case

;==============================================================================
; size_t asm_u64toa_base(uint64_t value, char *buf, size_t cap, unsigned base)
;==============================================================================
global asm_u64toa_base:function
asm_u64toa_base:
    mov     r10, rcx
    xor     r11d, r11d
    jmp     L_utoa_base_case

;==============================================================================
; size_t asm_u64tohex(uint64_t value, char *buf, size_t cap, int uppercase)
;==============================================================================
global asm_u64tohex:function
asm_u64tohex:
    mov     r10d, 16
    mov     r11d, ecx
    jmp     L_utoa_base_case

;==============================================================================
; size_t asm_i64toa(int64_t value, char *buf, size_t cap)
;------------------------------------------------------------------------------
; Direct write when cap fits a sign and 20 digits; otherwise the shared bounded
; path. The return value is the full length including the sign.
;==============================================================================
global asm_i64toa:function
asm_i64toa:
    cmp     rdx, 22                     ; '-' + 20 digits + NUL fits?
    jb      L_i64toa_small
    push    rbx
    mov     rbx, rsi
    mov     rax, rdi
    test    rax, rax
    jns     .pos
    neg     rax
    mov     byte [rsi], '-'
    inc     rsi
.pos:
    mov     rdi, rsi
    call    L_dec_forward
    mov     byte [rdi], 0
    mov     rax, rdi
    sub     rax, rbx
    pop     rbx
    ret

; ---- bounded fallback: format into scratch, then copy what fits ----
L_i64toa_small:
    push    r12                         ; preserve callee-saved
    push    r13
    push    r14
    push    r15
    sub     rsp, 80
    mov     r12, rsi                    ; r12 = buf
    mov     r13, rdx                    ; r13 = cap
    xor     r14d, r14d                  ; r14 = 1 when a '-' is needed
    mov     rax, rdi
    test    rax, rax
    jns     .pos
    neg     rax                         ; magnitude (INT64_MIN stays 2^63)
    mov     r14d, 1
.pos:
    mov     r9d, 10
    xor     r8d, r8d
    lea     r10, [rsp+80]
    call    L_gen_digits                ; r11 = digits, r15 = count
    ; ---- bounded write: sign then leading digits ----
    test    r13, r13
    jz      .out
    mov     rcx, r13
    dec     rcx                         ; writable bytes
    test    r14d, r14d
    jz      .nosign
    test    rcx, rcx
    jz      .nosign
    mov     byte [r12], '-'
    inc     r12
    dec     rcx
.nosign:
    cmp     rcx, r15
    jbe     .have
    mov     rcx, r15
.have:
    mov     rsi, r11
    mov     rdi, r12
    rep     movsb
    mov     byte [rdi], 0
.out:
    lea     rax, [r15+r14]              ; full length including the sign
    add     rsp, 80
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

section .rodata
L_nullstr:   db "(null)", 0
L_nilstr:    db "(nil)", 0
L_hexprefix: db "0x"
L_digits_lc: db "0123456789", 0
L_hexdig_lc: db "0123456789abcdef", 0
L_hexdig_uc: db "0123456789ABCDEF", 0
align 16
L_dec_pairs:
%assign i 0
%rep 100
    db '0' + (i / 10), '0' + (i % 10)
%assign i i+1
%endrep

GNU_STACK_NOTE
