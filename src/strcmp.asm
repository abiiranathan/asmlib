;==============================================================================
; strcmp.asm - high-performance string comparison (System V AMD64 ABI)
;------------------------------------------------------------------------------
; Implements:
;   int asm_strcmp    (const char *a, const char *b);
;   int asm_strncmp   (const char *a, const char *b, size_t n);
;   int asm_strcasecmp (const char *a, const char *b);
;   int asm_strncasecmp(const char *a, const char *b, size_t n);
;
; strcmp/strncmp use SWAR (SIMD-within-a-register) processing of 64 bits at a
; time: a zero-byte detector finds NUL terminators without a byte loop, and
; tzcnt locates the first differing byte. Before every 8-byte read the routine
; checks that both pointers sit at least 8 bytes below a page boundary, so the
; widening load can never touch an unmapped page.
;
; strcasecmp/strncasecmp fold ASCII letters with a branchless sequence and
; then compare bytes; behaviour matches the C/POSIX locale.
;==============================================================================

BITS 64
default rel

%include "common.inc"

; Branchless ASCII lower-casing of the 32-bit register given as the argument.
; Uses r8d as scratch (never edx, so a byte budget held in rdx survives).
%macro ASM_FOLD_LOWER 1
    lea     r8d, [%1 - 'A']             ; distance above 'A' (wraps if below)
    cmp     r8d, 'Z' - 'A'              ; within the uppercase range?
    setbe   r8b                         ; r8b = 1 if uppercase, else 0
    movzx   r8d, r8b                    ; r8d = 0 or 1
    shl     r8d, 5                      ; r8d = 0 or 32
    or      %1, r8d                     ; set the lower-case bit if uppercase
%endmacro

section .text

;==============================================================================
; int asm_strcmp(const char *a, const char *b)
;------------------------------------------------------------------------------
; Returns 0 if equal, otherwise the sign of the first differing byte pair.
;==============================================================================
global asm_strcmp:function
asm_strcmp:
    mov     r10, 0x0101010101010101     ; SWAR "low bit" constant
    mov     r11, 0x8080808080808080     ; SWAR "high bit" constant
.qloop:
    ; ---- page-safety gate: both pointers must allow an 8-byte read
    mov     eax, edi                    ; eax = low 12 bits of a
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-8            ; would the read cross the page end?
    ja      .byte                       ; yes: fall back to a byte step
    mov     eax, esi                    ; eax = low 12 bits of b
    and     eax, PAGE_SIZE-1
    cmp     eax, PAGE_SIZE-8
    ja      .byte
    ; ---- compare 8 bytes at a time
    mov     rax, [rdi]                  ; load 8 bytes of a
    mov     rcx, [rsi]                  ; load 8 bytes of b
    cmp     rax, rcx                    ; identical chunk?
    jne     .diff                       ; no: locate the differing byte
    ; ---- equal chunk: is there a NUL byte (in both, since they are equal)?
    mov     rdx, rax                    ; copy chunk
    sub     rdx, r10                    ; x - 0x01..01
    not     rax                         ; ~x
    and     rdx, rax                    ; (x-1) & ~x
    and     rdx, r11                    ; mask the high bits
    test    rdx, rdx                    ; any zero byte?
    jnz     .equal                      ; yes: both strings end here
    add     rdi, 8                      ; advance to the next chunk
    add     rsi, 8
    jmp     .qloop
.diff:
    mov     rdx, rax                    ; copy a's chunk
    xor     rdx, rcx                    ; bit positions that differ
    tzcnt   rdx, rdx                    ; lowest differing bit
    ; ---- check for a NUL in a that occurs before the difference
    mov     r8, rax                     ; copy a's chunk
    sub     r8, r10
    not     rax
    and     r8, rax
    and     r8, r11                     ; zero-byte flags of a
    test    r8, r8
    jz      .emit                       ; no NUL before the difference
    tzcnt   r8, r8                      ; bit of the first NUL
    cmp     r8, rdx                     ; NUL earlier than the difference?
    jb      .equal                      ; yes: the strings ended equally
.emit:
    shr     rdx, 3                      ; convert bit index to byte index
    movzx   eax, byte [rdi+rdx]         ; differing byte of a
    movzx   ecx, byte [rsi+rdx]         ; differing byte of b
    sub     eax, ecx                    ; signed result
    ret
.equal:
    xor     eax, eax                    ; strings are equal
    ret
.byte:
    movzx   eax, byte [rdi]             ; load one byte of a
    movzx   ecx, byte [rsi]             ; load one byte of b
    sub     eax, ecx                    ; compare
    jnz     .ret                        ; differing: done
    test    cl, cl                      ; both NUL (they were equal)?
    jz      .equal                      ; yes: equal
    inc     rdi                         ; advance one byte
    inc     rsi
    jmp     .qloop                      ; retry the fast path
.ret:
    ret

;==============================================================================
; int asm_strncmp(const char *a, const char *b, size_t n)
;------------------------------------------------------------------------------
; Compares at most n bytes. Returns 0 if the first n bytes are equal.
;==============================================================================
global asm_strncmp:function
asm_strncmp:
    mov     r8, 0x0101010101010101      ; SWAR "low bit" constant
    mov     r9, 0x8080808080808080      ; SWAR "high bit" constant
.loop:
    cmp     rdx, 8                      ; at least 8 bytes left?
    jb      .bytes                      ; no: finish with a byte loop
    ; ---- page-safety gate for an 8-byte read from both pointers
    mov     r10d, edi
    and     r10d, PAGE_SIZE-1
    cmp     r10d, PAGE_SIZE-8
    ja      .bytes
    mov     r10d, esi
    and     r10d, PAGE_SIZE-1
    cmp     r10d, PAGE_SIZE-8
    ja      .bytes
    ; ---- compare one 8-byte chunk
    mov     rax, [rdi]                  ; chunk of a
    mov     rcx, [rsi]                  ; chunk of b
    cmp     rax, rcx
    jne     .diff                       ; differ: locate the byte
    ; ---- equal chunk: check for a NUL byte
    mov     r10, rax
    sub     r10, r8
    mov     r11, rax
    not     r11
    and     r10, r11
    and     r10, r9
    test    r10, r10
    jnz     .equal                      ; NUL reached before n bytes
    add     rdi, 8
    add     rsi, 8
    sub     rdx, 8
    jmp     .loop
.diff:
    mov     r10, rax                    ; copy a's chunk
    xor     r10, rcx                    ; differing bits
    tzcnt   r10, r10                    ; lowest differing bit
    ; ---- look for a NUL in a before that bit
    mov     r11, rax
    sub     r11, r8
    not     rax
    and     r11, rax
    and     r11, r9
    test    r11, r11
    jz      .emit
    tzcnt   r11, r11
    cmp     r11, r10                    ; NUL before the difference?
    jb      .equal
.emit:
    shr     r10, 3                      ; bit index -> byte index
    movzx   eax, byte [rdi+r10]
    movzx   ecx, byte [rsi+r10]
    sub     eax, ecx
    ret
.equal:
    xor     eax, eax
    ret
.bytes:
    test    rdx, rdx                    ; no bytes left?
    jz      .equal
.byte_loop:
    movzx   eax, byte [rdi]             ; load a byte of a
    movzx   ecx, byte [rsi]             ; load a byte of b
    sub     eax, ecx                    ; compare
    jnz     .ret                        ; differing: done
    test    cl, cl                      ; NUL reached?
    jz      .equal                      ; yes: equal so far
    inc     rdi
    inc     rsi
    dec     rdx                         ; one fewer byte allowed
    jnz     .byte_loop
    jmp     .equal
.ret:
    ret

;==============================================================================
; int asm_strcasecmp(const char *a, const char *b)
;------------------------------------------------------------------------------
; Case-insensitive (C/POSIX locale) comparison of two NUL-terminated strings.
;==============================================================================
global asm_strcasecmp:function
asm_strcasecmp:
.loop:
    movzx   eax, byte [rdi]             ; byte of a
    movzx   ecx, byte [rsi]             ; byte of b
    ASM_FOLD_LOWER eax                  ; lower-case a
    ASM_FOLD_LOWER ecx                  ; lower-case b
    sub     eax, ecx                    ; folded comparison
    jnz     .ret                        ; differing: return
    test    ecx, ecx                    ; both folded to NUL?
    jz      .ret                        ; yes: equal (eax is 0)
    inc     rdi                         ; advance
    inc     rsi
    jmp     .loop
.ret:
    ret

;==============================================================================
; int asm_strncasecmp(const char *a, const char *b, size_t n)
;------------------------------------------------------------------------------
; Case-insensitive comparison of at most n bytes.
;==============================================================================
global asm_strncasecmp:function
asm_strncasecmp:
    test    rdx, rdx                    ; n == 0?
    jz      .equal                      ; yes: treated as equal
.loop:
    movzx   eax, byte [rdi]             ; byte of a
    movzx   ecx, byte [rsi]             ; byte of b
    ASM_FOLD_LOWER eax                  ; lower-case a
    ASM_FOLD_LOWER ecx                  ; lower-case b
    sub     eax, ecx                    ; folded comparison
    jnz     .ret                        ; differing: return
    test    ecx, ecx                    ; NUL reached?
    jz      .equal                      ; yes: equal so far
    inc     rdi                         ; advance
    inc     rsi
    dec     rdx                         ; consume one byte of the budget
    jnz     .loop
.equal:
    xor     eax, eax
.ret:
    ret

GNU_STACK_NOTE
