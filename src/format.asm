;==============================================================================
; format.asm - fast integer-to-string conversion and a minimal snprintf
;------------------------------------------------------------------------------
; Bounded integer formatters:
;
;   size_t asm_u64toa      (uint64_t v, char *buf, size_t cap);
;   size_t asm_i64toa      (int64_t  v, char *buf, size_t cap);
;   size_t asm_u64toa_base (uint64_t v, char *buf, size_t cap, unsigned base);
;   size_t asm_u64tohex    (uint64_t v, char *buf, size_t cap, int uppercase);
;
; and a small, fast replacement for the common cases of snprintf:
;
;   int asm_snprintf(char *dst, size_t size, const char *fmt, ...);
;
; The formatter supports %%, %c, %s, %p, %d, %i, %u, %x, %X and %o with the
; '-'/'0' flags, a decimal width and the l/ll length modifiers; see the header
; for the precise contract. It is deliberately not a full printf: no floating
; point, no precision, no '*', no locale, no %n.
;
; The number formatters never write more than `cap` bytes (including the NUL)
; and return the length the full number needs, so callers can detect
; truncation. asm_snprintf follows snprintf's return convention.
;
; Implementation notes
; --------------------
; Digits are generated into a small stack scratch buffer from the end
; backwards, then copied out most-significant first. The formatter keeps its
; output cursor, remaining capacity and would-be length in registers and
; appends through three primitives (putc/putn/putrep) that count every byte
; but only store the ones that fit. Integer and pointer conversions are emitted
; sign/prefix-first so zero padding lands in the right place.
;==============================================================================

BITS 64
default rel

%include "common.inc"

extern asm_strlen

; ---- asm_snprintf stack frame (all offsets relative to rbp) -----------------
%define F_REGCNT  (rbp-48)      ; qword: vararg GPRs consumed (0..3)
%define F_STK     (rbp-56)      ; qword: next stacked vararg
%define F_RCX     (rbp-80)      ; qword: saved first vararg (rcx)
%define F_R8      (rbp-72)      ; qword: saved second vararg (r8)
%define F_R9      (rbp-64)      ; qword: saved third vararg (r9)
%define F_FLAGS   (rbp-88)      ; qword: bit0 '-' left, bit1 '0' zero
%define F_WIDTH   (rbp-96)      ; qword: field width
%define F_LEN     (rbp-104)     ; qword: 1 when l/ll seen (64-bit integer)
%define F_SIGN    (rbp-112)     ; qword: sign/prefix/char scratch
%define F_PRE_PTR (rbp-120)
%define F_PRE_LEN (rbp-128)
%define F_DIG_PTR (rbp-136)
%define F_DIG_LEN (rbp-144)
%define F_PAD     (rbp-152)
%define BUF_END   (rbp-160)     ; 64-byte digit scratch sits below this

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
; internal: L_nextarg -> rax
;------------------------------------------------------------------------------
; Return the next integer vararg slot. The first three arguments (rcx, r8, r9)
; come from the saved register area; later ones come from the stack, starting
; at [rbp+16]. Every slot is a full 8 bytes; callers truncate as they need.
; Clobbers: rax, rdx
;==============================================================================
L_nextarg:
    mov     rax, [F_REGCNT]
    cmp     rax, 3
    jae     .stack
    mov     rdx, [F_RCX + rax*8]        ; rcx then r8 then r9
    inc     rax
    mov     [F_REGCNT], rax
    mov     rax, rdx
    ret
.stack:
    mov     rdx, [F_STK]
    mov     rax, [rdx]
    add     rdx, 8
    mov     [F_STK], rdx
    ret

;==============================================================================
; internal: L_putc(al) -> void
;------------------------------------------------------------------------------
; Append one byte, counting it even when the buffer is full. One byte is always
; kept free for the terminating NUL.
; Clobbers: flags only
;==============================================================================
L_putc:
    inc     r13                         ; would-be length
    cmp     r12, 1                      ; room beyond the reserved NUL?
    jbe     .ret
    mov     [rbx], al
    inc     rbx
    dec     r12
.ret:
    ret

;==============================================================================
; internal: L_putn(rdi=src, rsi=len) -> void
;------------------------------------------------------------------------------
; Append len bytes from src, counting all of them, storing only what fits.
; Clobbers: rax, rcx, rdx, rsi, rdi
;==============================================================================
L_putn:
    add     r13, rsi
    cmp     r12, 1
    jbe     .ret
    lea     rax, [r12-1]                ; bytes we may store
    cmp     rsi, rax
    jbe     .fit
    mov     rsi, rax
.fit:
    mov     rdx, rsi                    ; keep the stored count
    cmp     rdx, 16
    ja      .big
    ; ---- small copy (1..16 bytes): overlapping wide moves, no rep startup ----
    cmp     rdx, 8
    jb      .lt8
    mov     rax, [rdi]
    mov     rcx, [rdi+rdx-8]
    mov     [rbx], rax
    mov     [rbx+rdx-8], rcx
    jmp     .done
.lt8:
    cmp     rdx, 4
    jb      .lt4
    mov     eax, [rdi]
    mov     ecx, [rdi+rdx-4]
    mov     [rbx], eax
    mov     [rbx+rdx-4], ecx
    jmp     .done
.lt4:
    test    rdx, rdx
    jz      .done
    movzx   eax, byte [rdi]
    mov     [rbx], al
    cmp     rdx, 2
    jb      .done
    movzx   eax, byte [rdi+rdx-1]
    mov     [rbx+rdx-1], al
    cmp     rdx, 3
    jb      .done
    movzx   eax, byte [rdi+1]
    mov     [rbx+1], al
.done:
    add     rbx, rdx
    sub     r12, rdx
.ret:
    ret
.big:
    mov     rax, rdi
    mov     rdi, rbx
    mov     rsi, rax
    mov     rcx, rdx
    rep     movsb
    mov     rbx, rdi
    sub     r12, rdx
    ret

;==============================================================================
; internal: L_putrep(al=char, rsi=count) -> void
;------------------------------------------------------------------------------
; Append count copies of a byte, counting all of them, storing what fits.
; Clobbers: rax, rcx, rdx, rdi
;==============================================================================
L_putrep:
    add     r13, rsi
    cmp     r12, 1
    jbe     .ret
    lea     r10, [r12-1]                ; keep al (the fill byte) intact
    cmp     rsi, r10
    jbe     .fit
    mov     rsi, r10
.fit:
    mov     rdx, rsi
    cmp     rdx, 16
    ja      .big
    ; ---- small fill (1..16 bytes): replicate the byte into a qword ----
    movzx   eax, al
    mov     rcx, 0x0101010101010101
    imul    rax, rcx
    cmp     rdx, 8
    jb      .lt8
    mov     [rbx], rax
    mov     [rbx+rdx-8], rax
    jmp     .done
.lt8:
    cmp     rdx, 4
    jb      .lt4
    mov     [rbx], eax
    mov     [rbx+rdx-4], eax
    jmp     .done
.lt4:
    test    rdx, rdx
    jz      .done
    mov     [rbx], al
    cmp     rdx, 2
    jb      .done
    mov     [rbx+rdx-2], ax
.done:
    add     rbx, rdx
    sub     r12, rdx
.ret:
    ret
.big:
    mov     rdi, rbx
    mov     rcx, rdx
    rep     stosb
    mov     rbx, rdi
    sub     r12, rdx
    ret

;==============================================================================
; internal: L_emit_num(rdx:rsi prefix, r15:r11 digits) -> void
;------------------------------------------------------------------------------
; Emit prefix+digits with the current width and flags. Zero padding is placed
; after the prefix so "-00042" and "0x00ff" come out right.
;==============================================================================
L_emit_num:
    mov     [F_DIG_PTR], r11
    mov     [F_DIG_LEN], r15
    mov     [F_PRE_PTR], rsi
    mov     [F_PRE_LEN], rdx
    mov     rax, rdx
    add     rax, r15                    ; content length
    mov     rcx, [F_WIDTH]
    xor     r10d, r10d
    cmp     rcx, rax
    jbe     .nopad
    mov     r10, rcx
    sub     r10, rax
.nopad:
    mov     [F_PAD], r10
    mov     rax, [F_FLAGS]
    test    al, 1                       ; left justified?
    jnz     .left
    test    al, 2                       ; zero padded?
    jnz     .zero
    ; right justified, spaces: pad, prefix, digits
    cmp     qword [F_PAD], 0
    je      .rs_prefix
    mov     al, ' '
    mov     rsi, [F_PAD]
    call    L_putrep
.rs_prefix:
    cmp     qword [F_PRE_LEN], 0
    je      .rs_digits
    mov     rdi, [F_PRE_PTR]
    mov     rsi, [F_PRE_LEN]
    call    L_putn
.rs_digits:
    mov     rdi, [F_DIG_PTR]
    mov     rsi, [F_DIG_LEN]
    call    L_putn
    ret
.zero:
    cmp     qword [F_PRE_LEN], 0
    je      .z_zeros
    mov     rdi, [F_PRE_PTR]
    mov     rsi, [F_PRE_LEN]
    call    L_putn
.z_zeros:
    cmp     qword [F_PAD], 0
    je      .z_digits
    mov     al, '0'
    mov     rsi, [F_PAD]
    call    L_putrep
.z_digits:
    mov     rdi, [F_DIG_PTR]
    mov     rsi, [F_DIG_LEN]
    call    L_putn
    ret
.left:
    cmp     qword [F_PRE_LEN], 0
    je      .l_digits
    mov     rdi, [F_PRE_PTR]
    mov     rsi, [F_PRE_LEN]
    call    L_putn
.l_digits:
    mov     rdi, [F_DIG_PTR]
    mov     rsi, [F_DIG_LEN]
    call    L_putn
    cmp     qword [F_PAD], 0
    je      .l_done
    mov     al, ' '
    mov     rsi, [F_PAD]
    call    L_putrep
.l_done:
    ret

;==============================================================================
; internal: L_emit_str(r11=ptr, r15=len) -> void
;------------------------------------------------------------------------------
; Emit a known-length string with the current width (spaces only; '0' is
; ignored for strings, as in printf).
;==============================================================================
L_emit_str:
    mov     [F_DIG_PTR], r11
    mov     [F_DIG_LEN], r15
    mov     rcx, [F_WIDTH]
    xor     r10d, r10d
    cmp     rcx, r15
    jbe     .nopad
    mov     r10, rcx
    sub     r10, r15
.nopad:
    mov     [F_PAD], r10
    test    qword [F_FLAGS], 1
    jnz     .left
    mov     al, ' '
    mov     rsi, [F_PAD]
    call    L_putrep
    mov     rdi, [F_DIG_PTR]
    mov     rsi, [F_DIG_LEN]
    call    L_putn
    ret
.left:
    mov     rdi, [F_DIG_PTR]
    mov     rsi, [F_DIG_LEN]
    call    L_putn
    mov     al, ' '
    mov     rsi, [F_PAD]
    call    L_putrep
    ret

;==============================================================================
; int asm_snprintf(char *dst, size_t size, const char *fmt, ...)
;------------------------------------------------------------------------------
; A minimal snprintf; see include/asmlib.h for the supported conversions.
;
; Parameters (System V AMD64 ABI):
;   rdi = dst (char *)   - output buffer
;   rsi = size (size_t)  - buffer size, including the NUL
;   rdx = fmt (char *)   - format string
;   ...  = varargs in rcx, r8, r9 then on the stack
; Returns:
;   eax = number of bytes the output needs, excluding the NUL
;==============================================================================
global asm_snprintf:function
asm_snprintf:
    ; ---- prologue: frame, callee-saved registers, locals ----
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 184                    ; locals + 64-byte digit scratch
    ; ---- capture the vararg register half ----
    mov     qword [F_REGCNT], 0
    lea     rax, [rbp+16]               ; first stacked vararg
    mov     [F_STK], rax
    mov     [F_RCX], rcx
    mov     [F_R8], r8
    mov     [F_R9], r9
    ; ---- sink state ----
    mov     rbx, rdi                    ; rbx = write cursor
    mov     r12, rsi                    ; r12 = bytes left (incl. NUL)
    xor     r13d, r13d                  ; r13 = would-be length
    mov     r14, rdx                    ; r14 = format cursor
.loop:
    movzx   eax, byte [r14]
    inc     r14
    test    al, al
    jz      .done
    cmp     al, '%'
    je      .conv
    call    L_putc                      ; ordinary byte
    jmp     .loop

    ; ---- a conversion: flags, width, length modifier, specifier ----
.conv:
    mov     qword [F_FLAGS], 0
    mov     qword [F_WIDTH], 0
    mov     qword [F_LEN], 0
.flags:
    movzx   eax, byte [r14]
    cmp     al, '-'
    je      .flag_left
    cmp     al, '0'
    je      .flag_zero
    jmp     .width
.flag_left:
    or      qword [F_FLAGS], 1
    inc     r14
    jmp     .flags
.flag_zero:
    or      qword [F_FLAGS], 2
    inc     r14
    jmp     .flags
.width:
    movzx   eax, byte [r14]
    sub     eax, '0'
    cmp     eax, 9
    ja      .length
    mov     rcx, [F_WIDTH]
    imul    rcx, rcx, 10
    add     rcx, rax
    cmp     rcx, 0x7fffffff
    jbe     .w_ok
    mov     ecx, 0x7fffffff
.w_ok:
    mov     [F_WIDTH], rcx
    inc     r14
    jmp     .width
.length:
    cmp     byte [r14], 'l'
    jne     .spec
    mov     qword [F_LEN], 1
    inc     r14
    cmp     byte [r14], 'l'
    jne     .spec
    inc     r14
.spec:
    movzx   eax, byte [r14]
    inc     r14
    cmp     al, 'd'
    je      .int_signed
    cmp     al, 'i'
    je      .int_signed
    cmp     al, 'u'
    je      .uint
    cmp     al, 'x'
    je      .hex_lower
    cmp     al, 'X'
    je      .hex_upper
    cmp     al, 'o'
    je      .oct
    cmp     al, 'c'
    je      .char
    cmp     al, 's'
    je      .string
    cmp     al, 'p'
    je      .pointer
    cmp     al, '%'
    je      .percent
    ; unsupported: copy '%' and the specifier literally, no argument
    mov     al, '%'
    call    L_putc
    movzx   eax, byte [r14-1]
    call    L_putc
    jmp     .loop
.percent:
    mov     al, '%'
    call    L_putc
    jmp     .loop

    ; ---- signed decimal: '-' prefix, magnitude in base 10 ----
.int_signed:
    call    L_nextarg
    cmp     qword [F_LEN], 0
    jne     .is64
    movsxd  rax, eax                    ; default is a 32-bit int
.is64:
    xor     ecx, ecx
    test    rax, rax
    jns     .ispos
    neg     rax                         ; magnitude (INT64_MIN stays 2^63)
    mov     ecx, '-'
.ispos:
    mov     [F_SIGN], rcx
    mov     r15, rax
    mov     r9d, 10
    xor     r8d, r8d
    lea     r10, [BUF_END]
    call    L_gen_digits
    lea     rsi, [F_SIGN]
    mov     edx, 1
    cmp     qword [F_SIGN], 0
    jne     .ispre
    xor     edx, edx                    ; no sign -> empty prefix
.ispre:
    call    L_emit_num
    jmp     .loop

    ; ---- unsigned conversions: no prefix ----
.uint:
    call    L_nextarg
    cmp     qword [F_LEN], 0
    jne     .u64
    mov     eax, eax                    ; zero-extend the low 32 bits
.u64:
    mov     r15, rax
    mov     r9d, 10
    xor     r8d, r8d
    lea     r10, [BUF_END]
    call    L_gen_digits
    xor     esi, esi
    xor     edx, edx
    call    L_emit_num
    jmp     .loop
.hex_lower:
    xor     r8d, r8d
    jmp     .hex
.hex_upper:
    mov     r8d, 1
.hex:
    call    L_nextarg
    cmp     qword [F_LEN], 0
    jne     .h64
    mov     eax, eax
.h64:
    mov     r15, rax
    mov     r9d, 16
    lea     r10, [BUF_END]
    call    L_gen_digits
    xor     esi, esi
    xor     edx, edx
    call    L_emit_num
    jmp     .loop
.oct:
    call    L_nextarg
    cmp     qword [F_LEN], 0
    jne     .o64
    mov     eax, eax
.o64:
    mov     r15, rax
    mov     r9d, 8
    xor     r8d, r8d
    lea     r10, [BUF_END]
    call    L_gen_digits
    xor     esi, esi
    xor     edx, edx
    call    L_emit_num
    jmp     .loop

    ; ---- %c: one byte, space padded (never zero) ----
.char:
    call    L_nextarg
    mov     [F_SIGN], rax
    lea     r11, [F_SIGN]
    mov     r15, 1
    call    L_emit_str
    jmp     .loop

    ; ---- %s: known-length string, "(null)" for NULL ----
.string:
    call    L_nextarg
    test    rax, rax
    jnz     .str_ok
    lea     r11, [L_nullstr]
    mov     r15, 6
    jmp     .str_emit
.str_ok:
    mov     [F_SIGN], rax               ; asm_strlen clobbers caller-saved
    mov     rdi, rax
    call    asm_strlen
    mov     r15, rax
    mov     r11, [F_SIGN]
.str_emit:
    call    L_emit_str
    jmp     .loop

    ; ---- %p: "0x" + lowercase hex, "(nil)" for NULL ----
.pointer:
    call    L_nextarg
    test    rax, rax
    jnz     .ptr_ok
    lea     r11, [L_nilstr]
    mov     r15, 5
    call    L_emit_str
    jmp     .loop
.ptr_ok:
    mov     r15, rax
    mov     r9d, 16
    xor     r8d, r8d
    lea     r10, [BUF_END]
    call    L_gen_digits
    lea     rsi, [L_hexprefix]
    mov     edx, 2
    call    L_emit_num
    jmp     .loop

    ; ---- finish: NUL terminate when there is room, return the length ----
.done:
    test    r12, r12
    jz      .no_nul
    mov     byte [rbx], 0
.no_nul:
    mov     eax, r13d
    add     rsp, 184
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
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
